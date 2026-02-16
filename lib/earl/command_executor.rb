# frozen_string_literal: true

require "open3"
require "shellwords"

module Earl
  # Executes `!` commands parsed by CommandParser, dispatching to the
  # appropriate session manager or mattermost action.
  class CommandExecutor
    include Logging
    include Formatting

    HELP_TABLE = <<~HELP
      | Command | Description |
      |---------|-------------|
      | `!help` | Show this help table |
      | `!stats` | Show session stats (tokens, context, cost) |
      | `!usage` | Show Claude Pro subscription usage limits |
      | `!context` | Show context window usage for current session |
      | `!stop` | Kill current session |
      | `!escape` | Send SIGINT to Claude (interrupt) |
      | `!kill` | Force kill session |
      | `!compact` | Compact Claude's context |
      | `!cd <path>` | Set working directory for next session |
      | `!permissions` | Show current permission mode |
      | `!heartbeats` | Show heartbeat schedule status |
      | `!sessions` | List all tmux sessions |
      | `!session <name>` | Capture and show tmux pane output |
      | `!session <name> status` | AI-summarize session state |
      | `!session <name> kill` | Kill tmux session |
      | `!session <name> nudge` | Send nudge message to session |
      | `!session <name> approve` | Approve pending permission |
      | `!session <name> deny` | Deny pending permission |
      | `!session <name> "text"` | Send input to tmux session |
      | `!spawn "prompt" [--name N] [--dir D]` | Spawn Claude in a new tmux session |
    HELP

    # Commands that pass through to Claude as slash commands.
    PASSTHROUGH_COMMANDS = { compact: "/compact" }.freeze

    USAGE_SCRIPT = File.expand_path("../../bin/claude-usage", __dir__)
    CONTEXT_SCRIPT = File.expand_path("../../bin/claude-context", __dir__)

    # :reek:LongParameterList
    def initialize(session_manager:, mattermost:, config:, heartbeat_scheduler: nil, tmux_store: nil, tmux_adapter: Tmux)
      @session_manager = session_manager
      @mattermost = mattermost
      @config = config
      @heartbeat_scheduler = heartbeat_scheduler
      @tmux_store = tmux_store
      @tmux = tmux_adapter
      @working_dirs = {} # thread_id -> path
    end

    # Returns { passthrough: "/command" } for passthrough commands so the
    # runner can route them through the normal message pipeline.
    # Returns nil for all other commands (handled inline).
    # :reek:TooManyStatements :reek:FeatureEnvy
    def execute(command, thread_id:, channel_id:)
      name = command.name
      slash = PASSTHROUGH_COMMANDS[name]
      return { passthrough: slash } if slash

      args = command.args
      dispatch_command(name, thread_id, channel_id, args)
      nil
    end

    def working_dir_for(thread_id)
      @working_dirs[thread_id]
    end

    private

    # :reek:TooManyStatements :reek:ControlParameter :reek:LongParameterList :reek:DuplicateMethodCall
    def dispatch_command(name, thread_id, channel_id, args) # rubocop:disable Metrics/MethodLength
      arg = args.first
      case name
      when :help then handle_help(thread_id, channel_id)
      when :stats then handle_stats(thread_id, channel_id)
      when :stop then handle_stop(thread_id, channel_id)
      when :escape then handle_escape(thread_id, channel_id)
      when :kill then handle_kill(thread_id, channel_id)
      when :cd then handle_cd(thread_id, channel_id, arg)
      when :permissions then post_reply(channel_id, thread_id, "Permission mode is controlled via `EARL_SKIP_PERMISSIONS` env var.")
      when :heartbeats then handle_heartbeats(thread_id, channel_id)
      when :usage then handle_usage(thread_id, channel_id)
      when :context then handle_context(thread_id, channel_id)
      when :sessions then handle_sessions(thread_id, channel_id)
      when :session_show then handle_session_show(thread_id, channel_id, arg)
      when :session_status then handle_session_status(thread_id, channel_id, arg)
      when :session_kill then handle_session_kill(thread_id, channel_id, arg)
      when :session_nudge then handle_session_nudge(thread_id, channel_id, arg)
      when :session_approve then handle_session_approve(thread_id, channel_id, arg)
      when :session_deny then handle_session_deny(thread_id, channel_id, arg)
      when :session_input then handle_session_input(thread_id, channel_id, arg, args[1])
      when :spawn then handle_spawn(thread_id, channel_id, arg, args[1])
      end
    end

    def handle_help(thread_id, channel_id)
      post_reply(channel_id, thread_id, HELP_TABLE)
    end

    def handle_stats(thread_id, channel_id)
      session = @session_manager.get(thread_id)
      if session
        post_reply(channel_id, thread_id, format_stats(session.stats))
        return
      end

      persisted = @session_manager.persisted_session_for(thread_id)
      if persisted&.total_cost
        post_reply(channel_id, thread_id, format_persisted_stats(persisted))
      else
        post_reply(channel_id, thread_id, "No active session for this thread.")
      end
    end

    # :reek:FeatureEnvy
    def format_stats(stats)
      total_in = stats.total_input_tokens
      total_out = stats.total_output_tokens
      lines = [ "#### :bar_chart: Session Stats", "| Metric | Value |", "|--------|-------|" ]
      lines << "| **Total tokens** | #{format_number(total_in + total_out)} (in: #{format_number(total_in)}, out: #{format_number(total_out)}) |"
      append_optional_stats(lines, stats)
      lines << "| **Cost** | $#{format('%.4f', stats.total_cost)} |"
      lines.join("\n")
    end

    # :reek:FeatureEnvy
    def append_optional_stats(lines, stats)
      pct = stats.context_percent
      lines << "| **Context used** | #{format('%.1f%%', pct)} of #{format_number(stats.context_window)} |" if pct
      model = stats.model_id
      lines << "| **Model** | `#{model}` |" if model
      ttft = stats.time_to_first_token
      lines << "| **Last TTFT** | #{format('%.1fs', ttft)} |" if ttft
      tps = stats.tokens_per_second
      lines << "| **Last speed** | #{format('%.0f', tps)} tok/s |" if tps
    end

    # :reek:FeatureEnvy
    def format_persisted_stats(persisted)
      total_in = persisted.total_input_tokens || 0
      total_out = persisted.total_output_tokens || 0
      lines = [ "#### :bar_chart: Session Stats (stopped)", "| Metric | Value |", "|--------|-------|" ]
      lines << "| **Total tokens** | #{format_number(total_in + total_out)} (in: #{format_number(total_in)}, out: #{format_number(total_out)}) |"
      lines << "| **Cost** | $#{format('%.4f', persisted.total_cost)} |"
      lines.join("\n")
    end

    def handle_stop(thread_id, channel_id)
      @session_manager.stop_session(thread_id)
      post_reply(channel_id, thread_id, ":stop_sign: Session stopped.")
    end

    def handle_escape(thread_id, channel_id)
      session = @session_manager.get(thread_id)
      if session&.process_pid
        Process.kill("INT", session.process_pid)
        post_reply(channel_id, thread_id, ":warning: Sent SIGINT to Claude.")
      else
        post_reply(channel_id, thread_id, "No active session to interrupt.")
      end
    rescue Errno::ESRCH
      post_reply(channel_id, thread_id, "Process already exited.")
    end

    def handle_kill(thread_id, channel_id)
      session = @session_manager.get(thread_id)
      if session&.process_pid
        Process.kill("KILL", session.process_pid)
        cleanup_and_reply(thread_id, channel_id, ":skull: Session force killed.")
      else
        post_reply(channel_id, thread_id, "No active session to kill.")
      end
    rescue Errno::ESRCH
      cleanup_and_reply(thread_id, channel_id, "Process already exited, session cleaned up.")
    end

    def handle_cd(thread_id, channel_id, path)
      cleaned = path.to_s.strip
      if cleaned.empty?
        post_reply(channel_id, thread_id, ":x: Usage: `!cd <path>`")
        return
      end

      expanded = File.expand_path(cleaned)
      if Dir.exist?(expanded)
        @working_dirs[thread_id] = expanded
        post_reply(channel_id, thread_id, ":file_folder: Working directory set to `#{expanded}` (applies to next new session)")
      else
        post_reply(channel_id, thread_id, ":x: Directory not found: `#{expanded}`")
      end
    end

    def handle_heartbeats(thread_id, channel_id)
      unless @heartbeat_scheduler
        post_reply(channel_id, thread_id, "Heartbeat scheduler not configured.")
        return
      end

      statuses = @heartbeat_scheduler.status
      if statuses.empty?
        post_reply(channel_id, thread_id, "No heartbeats configured.")
        return
      end

      post_reply(channel_id, thread_id, format_heartbeats(statuses))
    end

    # :reek:TooManyStatements
    def handle_usage(thread_id, channel_id)
      post_reply(channel_id, thread_id, ":hourglass: Fetching usage data (takes ~15s)...")

      Thread.new do
        data = fetch_usage_data
        message = data ? format_usage(data) : ":x: Failed to fetch usage data."
        post_reply(channel_id, thread_id, message)
      rescue StandardError => error
        msg = error.message
        log(:error, "Usage command error: #{msg}")
        post_reply(channel_id, thread_id, ":x: Error fetching usage: #{msg}")
      end
    end

    # :reek:UtilityFunction
    def fetch_usage_data
      output, status = Open3.capture2(USAGE_SCRIPT, "--json", err: File::NULL)
      return nil unless status.success?

      JSON.parse(output)
    rescue JSON::ParserError
      nil
    end

    # :reek:FeatureEnvy :reek:DuplicateMethodCall
    def format_usage(data)
      lines = [ "#### :bar_chart: Claude Pro Usage" ]

      session = data["session"]
      lines << "- **Session:** #{session['percent_used']}% used — resets #{session['resets']}" if session&.dig("percent_used")

      week = data["week"]
      lines << "- **Week:** #{week['percent_used']}% used — resets #{week['resets']}" if week&.dig("percent_used")

      extra = data["extra"]
      lines << "- **Extra:** #{extra['percent_used']}% used (#{extra['spent']} / #{extra['budget']}) — resets #{extra['resets']}" if extra&.dig("percent_used")

      lines.join("\n")
    end

    # :reek:TooManyStatements
    def handle_context(thread_id, channel_id)
      sid = @session_manager.claude_session_id_for(thread_id)
      unless sid
        post_reply(channel_id, thread_id, "No session found for this thread.")
        return
      end

      post_reply(channel_id, thread_id, ":hourglass: Fetching context data (takes ~20s)...")

      Thread.new do
        data = fetch_context_data(sid)
        message = data ? format_context(data) : ":x: Failed to fetch context data."
        post_reply(channel_id, thread_id, message)
      rescue StandardError => error
        msg = error.message
        log(:error, "Context command error: #{msg}")
        post_reply(channel_id, thread_id, ":x: Error fetching context: #{msg}")
      end
    end

    # :reek:UtilityFunction
    def fetch_context_data(session_id)
      output, status = Open3.capture2(CONTEXT_SCRIPT, session_id, "--json", err: File::NULL)
      return nil unless status.success?

      JSON.parse(output)
    rescue JSON::ParserError
      nil
    end

    # :reek:FeatureEnvy :reek:DuplicateMethodCall :reek:TooManyStatements
    def format_context(data)
      lines = [ "#### :brain: Context Window Usage" ]
      lines << "- **Model:** `#{data['model']}`"
      lines << "- **Used:** #{data['used_tokens']} / #{data['total_tokens']} tokens (#{data['percent_used']})"

      cats = data["categories"]
      if cats
        lines << ""
        format_context_category(lines, cats, "messages", "Messages")
        format_context_category(lines, cats, "system_prompt", "System prompt")
        format_context_category(lines, cats, "system_tools", "System tools")
        format_context_category(lines, cats, "custom_agents", "Custom agents")
        format_context_category(lines, cats, "memory_files", "Memory files")
        format_context_category(lines, cats, "skills", "Skills")
        format_context_category(lines, cats, "free_space", "Free space")
        format_context_category(lines, cats, "autocompact_buffer", "Autocompact buffer")
      end

      lines.join("\n")
    end

    # :reek:LongParameterList
    def format_context_category(lines, cats, key, label)
      cat = cats[key]
      tokens = cat&.fetch("tokens", nil)
      return unless tokens

      pct_val = cat["percent"]
      pct = pct_val ? " (#{pct_val})" : ""
      lines << "- **#{label}:** #{tokens} tokens#{pct}"
    end

    # :reek:FeatureEnvy
    def format_heartbeats(statuses)
      lines = [
        "#### 🫀 Heartbeat Status",
        "| Name | Next Run | Last Run | Runs | Status |",
        "|------|----------|----------|------|--------|"
      ]
      statuses.each { |status| lines << format_heartbeat_row(status) }
      lines.join("\n")
    end

    # :reek:FeatureEnvy
    def format_heartbeat_row(status)
      next_run = format_time(status[:next_run_at])
      last_run = format_time(status[:last_run_at])
      state = heartbeat_status_label(status)
      "| #{status[:name]} | #{next_run} | #{last_run} | #{status[:run_count]} | #{state} |"
    end

    def heartbeat_status_label(status)
      if status[:running]
        "🟢 Running"
      elsif status[:last_error]
        "🔴 Error"
      else
        "⚪ Idle"
      end
    end

    def format_time(time)
      return "—" unless time

      time.strftime("%Y-%m-%d %H:%M")
    end

    def post_reply(channel_id, thread_id, message)
      @mattermost.create_post(channel_id: channel_id, message: message, root_id: thread_id)
    end

    def cleanup_and_reply(thread_id, channel_id, message)
      @session_manager.stop_session(thread_id)
      post_reply(channel_id, thread_id, message)
    end

    # -- Tmux session handlers ------------------------------------------------

    # :reek:TooManyStatements
    def handle_sessions(thread_id, channel_id)
      unless @tmux.available?
        post_reply(channel_id, thread_id, ":x: tmux is not installed.")
        return
      end

      panes = @tmux.list_all_panes
      if panes.empty?
        post_reply(channel_id, thread_id, "No tmux sessions running.")
        return
      end

      claude_panes = panes.select { |pane| @tmux.claude_on_tty?(pane[:tty]) }
      if claude_panes.empty?
        post_reply(channel_id, thread_id, "No Claude sessions found across #{panes.size} tmux panes.")
        return
      end

      lines = [
        "#### :computer: Claude Sessions (#{claude_panes.size})",
        "| Pane | Project | Status |",
        "|------|---------|--------|"
      ]
      claude_panes.each { |pane| lines << format_claude_pane_row(pane) }
      post_reply(channel_id, thread_id, lines.join("\n"))
    end

    # :reek:FeatureEnvy :reek:DuplicateMethodCall
    def format_claude_pane_row(pane)
      target = pane[:target]
      project = File.basename(pane[:path])
      status = detect_pane_status(target)
      "| `#{target}` | #{project} | #{PANE_STATUS_LABELS.fetch(status, "🟡 Idle")} |"
    end

    PANE_STATUS_LABELS = {
      active: "🟢 Active",
      permission: "🟠 Waiting for permission",
      idle: "🟡 Idle"
    }.freeze

    # Detects Claude pane state by checking the last few lines of output:
    # - :permission  — Claude is showing a "Do you want to proceed?" dialog
    # - :active      — Claude is processing ("esc to interrupt" visible)
    # - :idle        — waiting for user input
    # :reek:FeatureEnvy
    def detect_pane_status(target)
      output = @tmux.capture_pane(target, lines: 20)
      return :permission if output.include?("Do you want to proceed?")
      return :active if output.include?("esc to interrupt")

      :idle
    rescue Tmux::Error => error
      log(:debug, "detect_pane_status failed for #{target}: #{error.message}")
      :idle
    end

    # :reek:TooManyStatements
    def handle_session_show(thread_id, channel_id, name)
      with_tmux_session(thread_id, channel_id, name) do
        output = @tmux.capture_pane(name)
        truncated = truncate_output(output)
        post_reply(channel_id, thread_id, "#### :computer: `#{name}` pane output\n```\n#{truncated}\n```")
      end
    end

    def handle_session_status(thread_id, channel_id, name)
      with_tmux_session(thread_id, channel_id, name) do
        output = @tmux.capture_pane(name, lines: 200)
        truncated = truncate_output(output, 3000)
        post_reply(channel_id, thread_id,
                   "#### :mag: `#{name}` status\n```\n#{truncated}\n```\n_AI summary not yet implemented._")
      end
    end

    # :reek:LongParameterList
    def handle_session_input(thread_id, channel_id, name, text)
      with_tmux_session(thread_id, channel_id, name) do
        @tmux.send_keys(name, text)
        post_reply(channel_id, thread_id, ":keyboard: Sent to `#{name}`: `#{text}`")
      end
    end

    def handle_session_nudge(thread_id, channel_id, name)
      with_tmux_session(thread_id, channel_id, name) do
        @tmux.send_keys(name, "Are you stuck? What's your current status?")
        post_reply(channel_id, thread_id, ":wave: Nudged `#{name}`.")
      end
    end

    def handle_session_approve(thread_id, channel_id, name)
      with_tmux_session(thread_id, channel_id, name) do
        @tmux.send_keys_raw(name, "Enter")
        post_reply(channel_id, thread_id, ":white_check_mark: Approved permission on `#{name}`.")
      end
    end

    def handle_session_deny(thread_id, channel_id, name)
      with_tmux_session(thread_id, channel_id, name) do
        @tmux.send_keys_raw(name, "Escape")
        post_reply(channel_id, thread_id, ":no_entry_sign: Denied permission on `#{name}`.")
      end
    end

    def handle_session_kill(thread_id, channel_id, name)
      @tmux.kill_session(name)
      @tmux_store&.delete(name)
      post_reply(channel_id, thread_id, ":skull: Tmux session `#{name}` killed.")
    rescue Tmux::NotFound
      @tmux_store&.delete(name)
      post_reply(channel_id, thread_id, ":x: Session `#{name}` not found (cleaned up store).")
    rescue Tmux::Error => error
      post_reply(channel_id, thread_id, ":x: Error killing session: #{error.message}")
    end

    # :reek:TooManyStatements :reek:LongParameterList
    def handle_spawn(thread_id, channel_id, prompt, flags_str)
      if prompt.to_s.strip.empty?
        post_reply(channel_id, thread_id, ":x: Usage: `!spawn \"prompt\" [--name N] [--dir D]`")
        return
      end

      flags = parse_spawn_flags(flags_str.to_s)
      name = flags[:name] || "earl-#{Time.now.strftime('%Y%m%d%H%M%S')}"
      working_dir = flags[:dir]

      if name.match?(/[.:]/)
        post_reply(channel_id, thread_id, ":x: Invalid session name `#{name}`: cannot contain `.` or `:` (tmux reserved).")
        return
      end

      if working_dir && !Dir.exist?(working_dir)
        post_reply(channel_id, thread_id, ":x: Directory not found: `#{working_dir}`")
        return
      end

      if @tmux.session_exists?(name)
        post_reply(channel_id, thread_id, ":x: Session `#{name}` already exists.")
        return
      end

      spawn_tmux_session(name: name, prompt: prompt, working_dir: working_dir,
                         channel_id: channel_id, thread_id: thread_id)
    rescue Tmux::Error => error
      post_reply(channel_id, thread_id, ":x: Failed to spawn session: #{error.message}")
    end

    # :reek:TooManyStatements :reek:LongParameterList
    def spawn_tmux_session(name:, prompt:, working_dir:, channel_id:, thread_id:)
      command = "claude #{Shellwords.shellescape(prompt)}"
      @tmux.create_session(name: name, command: command, working_dir: working_dir)

      save_tmux_session_info(name: name, channel_id: channel_id, thread_id: thread_id,
                             working_dir: working_dir, prompt: prompt)

      post_reply(channel_id, thread_id,
                 ":rocket: Spawned tmux session `#{name}`\n" \
                 "- **Prompt:** #{prompt}\n" \
                 "- **Dir:** #{working_dir || Dir.pwd}\n" \
                 "Use `!session #{name}` to check output.")
    end

    # :reek:LongParameterList
    def save_tmux_session_info(name:, channel_id:, thread_id:, working_dir:, prompt:)
      return unless @tmux_store

      info = TmuxSessionStore::TmuxSessionInfo.new(
        name: name, channel_id: channel_id, thread_id: thread_id,
        working_dir: working_dir, prompt: prompt, created_at: Time.now.iso8601
      )
      @tmux_store.save(info)
    end

    def truncate_output(output, max_length = 3500)
      output.length > max_length ? "…#{output[-max_length..]}" : output
    end

    def with_tmux_session(thread_id, channel_id, name)
      yield
    rescue Tmux::NotFound
      post_reply(channel_id, thread_id, ":x: Session `#{name}` not found.")
    rescue Tmux::Error => error
      post_reply(channel_id, thread_id, ":x: Error: #{error.message}")
    end

    # :reek:DuplicateMethodCall
    def parse_spawn_flags(str)
      {
        dir: str[/--dir\s+(\S+)/, 1],
        name: str[/--name\s+(\S+)/, 1]
      }.compact
    end
  end
end
