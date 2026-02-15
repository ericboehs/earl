# frozen_string_literal: true

module Earl
  # Lightweight background poller that monitors EARL-spawned tmux sessions for
  # state changes (questions, permission prompts, errors, completion, stalls)
  # and posts alerts to Mattermost. Also handles forwarding user reactions
  # back to tmux sessions as keyboard input.
  # :reek:TooManyConstants :reek:TooManyInstanceVariables :reek:TooManyMethods :reek:DataClump
  class TmuxMonitor
    include Logging

    EMOJI_NUMBERS = QuestionHandler::EMOJI_NUMBERS
    EMOJI_MAP = QuestionHandler::EMOJI_MAP

    DEFAULT_POLL_INTERVAL = 45 # seconds
    DEFAULT_STALL_THRESHOLD = 5 # consecutive unchanged polls

    # Pattern matchers for detecting session state from captured output.
    # Order matters: more specific patterns are checked first.
    # NOTE: :completed is handled separately via SHELL_PROMPT_PATTERN on last lines.
    STATE_PATTERNS = {
      asking_question: /\?\s*\n\s*(?:1[\.\)]\s|❯)/m,
      requesting_permission: /(?:Allow|Deny|approve|permission|Do you want to allow)/i,
      errored: /(?:Error:|error:|FAILED|panic:|Traceback|fatal:)/
    }.freeze

    SHELL_PROMPT_PATTERN = /[❯#%]\s*\z|\$\s+\z/

    # :reek:TooManyStatements :reek:DataClump :reek:UnusedParameters
    def initialize(mattermost:, tmux_store:, config: nil, tmux_adapter: Tmux)
      @mattermost = mattermost
      @tmux_store = tmux_store
      @tmux = tmux_adapter
      @poll_interval = Integer(ENV.fetch("EARL_TMUX_POLL_INTERVAL", DEFAULT_POLL_INTERVAL))
      @stall_threshold = Integer(ENV.fetch("EARL_TMUX_STALL_THRESHOLD", DEFAULT_STALL_THRESHOLD))

      @last_states = {}    # session_name -> state symbol
      @output_hashes = {}  # session_name -> { hash:, count: }
      @pending_interactions = {} # post_id -> { session_name:, type:, options: }
      @mutex = Mutex.new
      @thread = nil
      @shutdown = false
    end

    def start
      return if @thread&.alive?

      @shutdown = false
      @thread = Thread.new { poll_loop }
      log(:info, "TmuxMonitor started (interval: #{@poll_interval}s)")
    end

    def stop
      @shutdown = true
      if @thread
        @thread.join(5)
        @thread.kill if @thread.alive?
        @thread = nil
      end
      log(:info, "TmuxMonitor stopped")
    end

    # Called by Runner when a user reacts to a forwarded question/permission post.
    # Returns true if the reaction was handled, nil otherwise.
    def handle_reaction(post_id:, emoji_name:)
      interaction = @mutex.synchronize { @pending_interactions[post_id] }
      return nil unless interaction

      case interaction[:type]
      when :question
        handle_question_reaction(interaction, emoji_name, post_id)
      when :permission
        handle_permission_reaction(interaction, emoji_name, post_id)
      end
    end

    private

    def poll_loop
      until @shutdown
        sleep @poll_interval
        break if @shutdown

        begin
          poll_sessions
        rescue StandardError => error
          log(:error, "TmuxMonitor poll error: #{error.message}")
        end
      end
    end

    # :reek:TooManyStatements
    def poll_sessions
      sessions = @tmux_store.all
      cleanup_dead_sessions(sessions)

      sessions.each do |name, info|
        next unless @tmux.session_exists?(name)

        output = safe_capture(name)
        next unless output

        state = detect_state(output, name)
        handle_state_change(name, state, output, info) if state_changed?(name, state)
      rescue StandardError => error
        log(:error, "TmuxMonitor: error polling session '#{name}': #{error.message}")
      end
    end

    def cleanup_dead_sessions(sessions)
      sessions.each do |name, info|
        next if @tmux.session_exists?(name)

        log(:info, "TmuxMonitor: session '#{name}' no longer exists, cleaning up")
        post_alert(info, ":tombstone: Tmux session `#{name}` has ended.")
        @tmux_store.delete(name)
        @last_states.delete(name)
        @output_hashes.delete(name)
      end
    end

    def safe_capture(name)
      @tmux.capture_pane(name, lines: 50)
    rescue Tmux::Error => error
      log(:warn, "TmuxMonitor: failed to capture '#{name}': #{error.message}")
      nil
    end

    # :reek:FeatureEnvy :reek:DuplicateMethodCall
    def detect_state(output, name)
      last_lines = output.lines.last(3)&.join || ""

      # Check for shell prompt → completed (Claude exited back to shell)
      return :completed if last_lines.match?(SHELL_PROMPT_PATTERN)

      # Check pattern-based states against recent output only to avoid
      # matching keywords that appear in discussion text further up.
      recent = output.lines.last(15)&.join || ""
      STATE_PATTERNS.each do |state, pattern|
        return state if recent.match?(pattern)
      end

      # Stall detection: compare output hashes between polls
      return :stalled if stalled?(name, output)

      :running
    end

    # :reek:FeatureEnvy :reek:DuplicateMethodCall
    def stalled?(name, output)
      current_hash = output.hash
      entry = @output_hashes[name]

      if entry && entry[:hash] == current_hash
        entry[:count] += 1
        entry[:count] >= @stall_threshold
      else
        @output_hashes[name] = { hash: current_hash, count: 1 }
        false
      end
    end

    # :reek:FeatureEnvy :reek:DuplicateMethodCall
    def state_changed?(name, state)
      previous = @last_states[name]
      return true if previous != state
      # Re-trigger for interactive states even if same, so user sees repeated prompts
      return true if %i[asking_question requesting_permission].include?(state)

      false
    end

    # :reek:TooManyStatements :reek:LongParameterList
    def handle_state_change(name, state, output, info)
      @last_states[name] = state

      case state
      when :asking_question
        forward_question(name, output, info)
      when :requesting_permission
        forward_permission(name, output, info)
      when :errored
        post_alert(info, ":x: Session `#{name}` encountered an error:\n```\n#{last_lines_of(output, 10)}\n```")
      when :completed
        post_alert(info, ":white_check_mark: Session `#{name}` appears to have completed (shell prompt detected).")
      when :stalled
        post_alert(info, ":hourglass: Session `#{name}` appears stalled (output unchanged for #{@stall_threshold} polls).")
      end
    end

    # -- Question forwarding ---------------------------------------------------

    # :reek:TooManyStatements :reek:DuplicateMethodCall
    def forward_question(name, output, info)
      parsed = parse_question(output)
      return unless parsed

      lines = [ ":question: **Tmux `#{name}`** is asking:" ]
      lines << "```"
      lines << parsed[:text]
      lines << "```"
      parsed[:options].each_with_index do |opt, idx|
        emoji = EMOJI_NUMBERS[idx]
        lines << ":#{emoji}: #{opt}" if emoji
      end

      post = post_alert(info, lines.join("\n"))
      return unless post

      post_id = post["id"]
      add_emoji_reactions(post_id, parsed[:options].size)
      @mutex.synchronize do
        @pending_interactions[post_id] = {
          session_name: name, type: :question, options: parsed[:options]
        }
      end
    end

    # :reek:TooManyStatements
    def parse_question(output)
      # Look for a question mark followed by numbered options
      lines = output.lines.map(&:strip).reject(&:empty?)
      question_idx = lines.rindex { |line| line.include?("?") }
      return nil unless question_idx

      # Gather numbered options after the question
      options = []
      (question_idx + 1...lines.size).each do |idx|
        line = lines[idx]
        if line.match?(/\A\s*\d+[\.\)]\s/)
          options << line.sub(/\A\s*\d+[\.\)]\s*/, "")
        end
      end

      return nil if options.empty?

      { text: lines[question_idx], options: options.first(4) }
    end

    # -- Permission forwarding -------------------------------------------------

    # :reek:TooManyStatements
    def forward_permission(name, output, info)
      context = last_lines_of(output, 15)

      lines = [
        ":lock: **Tmux `#{name}`** is requesting permission:",
        "```",
        context,
        "```",
        ":white_check_mark: Approve  |  :x: Deny"
      ]

      post = post_alert(info, lines.join("\n"))
      return unless post

      post_id = post["id"]
      @mattermost.add_reaction(post_id: post_id, emoji_name: "white_check_mark")
      @mattermost.add_reaction(post_id: post_id, emoji_name: "x")

      @mutex.synchronize do
        @pending_interactions[post_id] = { session_name: name, type: :permission }
      end
    end

    # -- Reaction handlers -----------------------------------------------------

    # :reek:TooManyStatements
    def handle_question_reaction(interaction, emoji_name, post_id)
      answer_index = EMOJI_MAP[emoji_name]
      return nil unless answer_index

      options = interaction[:options]
      return nil unless answer_index < options.size

      # Send the option number (1-indexed) to tmux
      @tmux.send_keys(interaction[:session_name], (answer_index + 1).to_s)
      @mutex.synchronize { @pending_interactions.delete(post_id) }
      true
    rescue Tmux::Error => error
      log(:error, "TmuxMonitor: failed to send question answer: #{error.message}")
      nil
    end

    # :reek:TooManyStatements :reek:ControlParameter
    def handle_permission_reaction(interaction, emoji_name, post_id)
      answer = case emoji_name
      when "white_check_mark" then "y"
      when "x" then "n"
      end
      return nil unless answer

      @tmux.send_keys(interaction[:session_name], answer)
      @mutex.synchronize { @pending_interactions.delete(post_id) }
      true
    rescue Tmux::Error => error
      log(:error, "TmuxMonitor: failed to send permission answer: #{error.message}")
      nil
    end

    # -- Helpers ---------------------------------------------------------------

    # :reek:DuplicateMethodCall
    def add_emoji_reactions(post_id, count)
      [ count, EMOJI_NUMBERS.size ].min.times do |idx|
        @mattermost.add_reaction(post_id: post_id, emoji_name: EMOJI_NUMBERS[idx])
      rescue StandardError => error
        log(:warn, "TmuxMonitor: failed to add reaction :#{EMOJI_NUMBERS[idx]}: #{error.message}")
      end
    end

    def post_alert(info, message)
      @mattermost.create_post(
        channel_id: info.channel_id,
        message: message,
        root_id: info.thread_id
      )
    rescue StandardError => error
      log(:error, "TmuxMonitor: failed to post alert: #{error.message}")
      nil
    end

    def last_lines_of(output, count)
      output.lines.last(count)&.join || ""
    end
  end
end
