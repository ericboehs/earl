# frozen_string_literal: true

require_relative "tmux_monitor/question_forwarder"
require_relative "tmux_monitor/permission_forwarder"

module Earl
  # Lightweight background poller that monitors EARL-spawned tmux sessions for
  # state changes (questions, permission prompts, errors, completion, stalls)
  # and posts alerts to Mattermost. Also handles forwarding user reactions
  # back to tmux sessions as keyboard input.
  class TmuxMonitor
    include Logging

    DEFAULT_POLL_INTERVAL = 45 # seconds
    DEFAULT_STALL_THRESHOLD = 5 # consecutive unchanged polls

    # Pattern matchers for detecting session state from captured output.
    STATE_PATTERNS = {
      asking_question: /\?\s*\n\s*(?:1[\.\)]\s|❯)/m,
      requesting_permission: /(?:Allow|Deny|approve|permission|Do you want to allow)/i,
      errored: /(?:Error:|error:|FAILED|panic:|Traceback|fatal:)/
    }.freeze

    INTERACTIVE_STATES = { asking_question: :question, requesting_permission: :permission }.freeze

    def initialize(mattermost:, tmux_store:, tmux_adapter: Tmux)
      @poll_state = PollState.new(stall_threshold: Integer(ENV.fetch("EARL_TMUX_STALL_THRESHOLD", DEFAULT_STALL_THRESHOLD)))
      @deps = Dependencies.new(mattermost, tmux_store, tmux_adapter, @poll_state)
      @poll_interval = Integer(ENV.fetch("EARL_TMUX_POLL_INTERVAL", DEFAULT_POLL_INTERVAL))
      @thread_ctl = ThreadControl.new
    end

    def start
      return if @thread_ctl.alive?

      @thread_ctl.start { poll_loop }
      log(:info, "TmuxMonitor started (interval: #{@poll_interval}s)")
    end

    def stop
      @thread_ctl.stop
      log(:info, "TmuxMonitor stopped")
    end

    # Called by Runner when a user reacts to a forwarded question/permission post.
    # Returns true if the reaction was handled, nil otherwise.
    def handle_reaction(post_id:, emoji_name:)
      interaction = @poll_state.pending_interaction(post_id)
      return nil unless interaction

      case interaction[:type]
      when :question
        @deps.question_forwarder.handle_reaction(interaction, emoji_name, post_id)
      when :permission
        @deps.permission_forwarder.handle_reaction(interaction, emoji_name, post_id)
      end
    end

    # Delegate parse_question to QuestionForwarder for external callers.
    def parse_question(output)
      @deps.question_forwarder.parse_question(output)
    end

    private

    def poll_loop
      loop do
        sleep @poll_interval
        break if @thread_ctl.shutdown?

        poll_sessions
      rescue StandardError => error
        log(:error, "TmuxMonitor poll error: #{error.message}\n#{error.backtrace&.first(5)&.join("\n")}")
      end
    end

    def poll_sessions
      sessions = @deps.tmux_store.all
      cleanup_dead_sessions(sessions)

      sessions.each do |name, info|
        poll_single_session(name, info)
      rescue StandardError => error
        log(:error, "TmuxMonitor: error polling session '#{name}': #{error.message}\n#{error.backtrace&.first(5)&.join("\n")}")
      end
    end

    def poll_single_session(name, info)
      return unless @deps.tmux.session_exists?(name)

      output = safe_capture(name)
      return unless output

      state = OutputAnalyzer.detect(output, name, @poll_state)
      return unless @poll_state.transition(name, state)

      dispatch_state_alert(state, name: name, output: output, info: info)
    end

    def dispatch_state_alert(state, **context)
      name, output, info = context.values_at(:name, :output, :info)
      forwarder = { asking_question: @deps.question_forwarder,
                    requesting_permission: @deps.permission_forwarder }[state]
      if forwarder
        forwarder.forward(name, output, info)
      else
        msg = { errored: error_message(name, output),
                completed: completed_message(name),
                stalled: stalled_message(name) }[state]
        post_alert(info, msg) if msg
      end
    end

    def error_message(name, output)
      ":x: Session `#{name}` encountered an error:\n```\n#{output.lines.last(10)&.join}\n```"
    end

    def completed_message(name)
      ":white_check_mark: Session `#{name}` appears to have completed (shell prompt detected)."
    end

    def stalled_message(name)
      ":hourglass: Session `#{name}` appears stalled (output unchanged for #{@poll_state.stall_threshold} polls)."
    end

    def cleanup_dead_sessions(sessions)
      sessions.each do |name, info|
        next if @deps.tmux.session_exists?(name)

        log(:info, "TmuxMonitor: session '#{name}' no longer exists, cleaning up")
        post_alert(info, ":tombstone: Tmux session `#{name}` has ended.")
        @deps.tmux_store.delete(name)
        @poll_state.cleanup_session(name)
      end
    end

    def safe_capture(name)
      @deps.tmux.capture_pane(name, lines: 50)
    rescue Tmux::Error => error
      log(:warn, "TmuxMonitor: failed to capture '#{name}': #{error.message}")
      nil
    end

    def post_alert(info, message)
      @deps.mattermost.create_post(
        channel_id: info.channel_id,
        message: message,
        root_id: info.thread_id
      )
    rescue StandardError => error
      log(:error, "TmuxMonitor: failed to post alert (#{error.class}): #{error.message}")
      nil
    end

    # Stateless output analysis that detects tmux session state from captured text.
    module OutputAnalyzer
      SHELL_PROMPT_PATTERN = /[❯#%]\s*\z|\$\s+\z/

      module_function

      def detect(output, name, poll_state)
        all_lines = output.lines
        return :completed if completed?(all_lines)

        state_from_patterns(all_lines) || stall_or_running(name, output, poll_state)
      end

      def completed?(all_lines)
        (all_lines.last(3)&.join || "").match?(SHELL_PROMPT_PATTERN)
      end

      def state_from_patterns(all_lines)
        recent = all_lines.last(15)&.join || ""
        STATE_PATTERNS.each do |state, pattern|
          return state if recent.match?(pattern)
        end
        nil
      end

      def stall_or_running(name, output, poll_state)
        poll_state.stalled?(name, output) ? :stalled : :running
      end
    end

    # Bundles external service dependencies and forwarder collaborators.
    Forwarders = Struct.new(:question, :permission, keyword_init: true)

    # Holds external service references and forwarder pair.
    class Dependencies
      attr_reader :mattermost, :tmux_store, :tmux

      def initialize(mattermost, tmux_store, tmux_adapter, poll_state)
        @mattermost = mattermost
        @tmux_store = tmux_store
        @tmux = tmux_adapter
        shared = { mattermost: mattermost, tmux: tmux_adapter,
                   pending_interactions: poll_state.pending_interactions, mutex: poll_state.mutex }
        @forwarders = Forwarders.new(
          question: QuestionForwarder.new(**shared),
          permission: PermissionForwarder.new(**shared)
        )
      end

      def question_forwarder = @forwarders.question
      def permission_forwarder = @forwarders.permission
    end

    # Encapsulates mutable poll tracking state: last-seen states, output hashes
    # for stall detection, and pending user interactions.
    class PollState
      # Tracks per-session poll state: last detected state, output hash for stall detection.
      TrackingEntry = Struct.new(:last_state, :output_hash, :stall_count, keyword_init: true) do
        def update_stall(current_hash, threshold)
          if output_hash == current_hash
            self.stall_count += 1
            stall_count >= threshold
          else
            self.output_hash = current_hash
            self.stall_count = 1
            false
          end
        end
      end

      attr_reader :pending_interactions, :mutex, :stall_threshold

      def initialize(stall_threshold: DEFAULT_STALL_THRESHOLD)
        @tracking = {}
        @pending_interactions = {}
        @mutex = Mutex.new
        @stall_threshold = stall_threshold
      end

      def pending_interaction(post_id)
        @mutex.synchronize { @pending_interactions[post_id] }
      end

      # Returns true if state changed (and records the new state), false otherwise.
      def transition(name, state)
        tracking = ensure_tracking(name)
        last_state = tracking.last_state
        interaction_type = INTERACTIVE_STATES[state]
        should_retrigger = interaction_type && @mutex.synchronize {
          @pending_interactions.none? { |_, interaction| interaction[:session_name] == name && interaction[:type] == interaction_type }
        }
        changed = last_state != state || should_retrigger
        return false unless changed

        tracking.last_state = state
        true
      end

      def stalled?(name, output)
        ensure_tracking(name).update_stall(output.hash, @stall_threshold)
      end

      def cleanup_session(name)
        @tracking.delete(name)
        @mutex.synchronize do
          @pending_interactions.delete_if { |_, interaction| interaction[:session_name] == name }
        end
      end

      private

      def ensure_tracking(name)
        @tracking[name] ||= TrackingEntry.new(last_state: nil, output_hash: nil, stall_count: 0)
      end
    end

    # Simple background thread lifecycle wrapper.
    class ThreadControl
      def initialize
        @thread = nil
        @shutdown = false
      end

      def alive?
        @thread&.alive?
      end

      def shutdown?
        @shutdown
      end

      def start(&block)
        @shutdown = false
        @thread = Thread.new(&block)
      end

      def stop
        @shutdown = true
        return unless @thread

        @thread.join(5)
        @thread.kill if @thread.alive?
        @thread = nil
      end
    end
  end
end
