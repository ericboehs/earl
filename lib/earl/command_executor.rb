# frozen_string_literal: true

require "open3"
require "shellwords"

module Earl
  # Executes `!` commands parsed by CommandParser, dispatching to the
  # appropriate session manager or mattermost action.
  class CommandExecutor
    include Logging
    include Formatting

    # Bundles dispatch context so thread_id + channel_id don't travel as separate args.
    CommandContext = Data.define(:thread_id, :channel_id, :arg, :args)

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
    def execute(command, thread_id:, channel_id:)
      slash = PASSTHROUGH_COMMANDS[command.name]
      return { passthrough: slash } if slash

      ctx = CommandContext.new(
        thread_id: thread_id, channel_id: channel_id,
        arg: command.args.first, args: command.args
      )
      dispatch_command(command.name, ctx)
      nil
    end

    def working_dir_for(thread_id)
      @working_dirs[thread_id]
    end

    private

    def dispatch_command(name, ctx)
      case name
      when :help then handle_help(ctx)
      when :stats then handle_stats(ctx)
      when :stop then handle_stop(ctx)
      when :escape then handle_escape(ctx)
      when :kill then handle_kill(ctx)
      when :cd then handle_cd(ctx)
      when :permissions then post_reply(ctx, "Permission mode is controlled via `EARL_SKIP_PERMISSIONS` env var.")
      when :heartbeats then handle_heartbeats(ctx)
      when :usage then handle_usage(ctx)
      when :context then handle_context(ctx)
      when :sessions then handle_sessions(ctx)
      when :session_show then handle_session_show(ctx)
      when :session_status then handle_session_status(ctx)
      when :session_kill then handle_session_kill(ctx)
      when :session_nudge then handle_session_nudge(ctx)
      when :session_approve then handle_session_approve(ctx)
      when :session_deny then handle_session_deny(ctx)
      when :session_input then handle_session_input(ctx)
      when :spawn then handle_spawn(ctx)
      end
    end

    def handle_help(ctx)
      post_reply(ctx, HELP_TABLE)
    end

    def handle_stats(ctx)
      session = @session_manager.get(ctx.thread_id)
      if session
        post_reply(ctx, format_stats(session.stats))
        return
      end

      persisted = @session_manager.persisted_session_for(ctx.thread_id)
      if persisted&.total_cost
        post_reply(ctx, format_persisted_stats(persisted))
      else
        post_reply(ctx, "No active session for this thread.")
      end
    end

    def format_stats(stats)
      total_in = stats.total_input_tokens
      total_out = stats.total_output_tokens
      lines = [ "#### :bar_chart: Session Stats", "| Metric | Value |", "|--------|-------|" ]
      lines << "| **Total tokens** | #{format_number(total_in + total_out)} (in: #{format_number(total_in)}, out: #{format_number(total_out)}) |"
      append_optional_stats(lines, stats)
      lines << "| **Cost** | $#{format('%.4f', stats.total_cost)} |"
      lines.join("\n")
    end

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

    def format_persisted_stats(persisted)
      total_in = persisted.total_input_tokens || 0
      total_out = persisted.total_output_tokens || 0
      lines = [ "#### :bar_chart: Session Stats (stopped)", "| Metric | Value |", "|--------|-------|" ]
      lines << "| **Total tokens** | #{format_number(total_in + total_out)} (in: #{format_number(total_in)}, out: #{format_number(total_out)}) |"
      lines << "| **Cost** | $#{format('%.4f', persisted.total_cost)} |"
      lines.join("\n")
    end

    def handle_stop(ctx)
      @session_manager.stop_session(ctx.thread_id)
      post_reply(ctx, ":stop_sign: Session stopped.")
    end

    def handle_escape(ctx)
      session = @session_manager.get(ctx.thread_id)
      if session&.process_pid
        Process.kill("INT", session.process_pid)
        post_reply(ctx, ":warning: Sent SIGINT to Claude.")
      else
        post_reply(ctx, "No active session to interrupt.")
      end
    rescue Errno::ESRCH
      post_reply(ctx, "Process already exited.")
    end

    def handle_kill(ctx)
      session = @session_manager.get(ctx.thread_id)
      if session&.process_pid
        Process.kill("KILL", session.process_pid)
        cleanup_and_reply(ctx, ":skull: Session force killed.")
      else
        post_reply(ctx, "No active session to kill.")
      end
    rescue Errno::ESRCH
      cleanup_and_reply(ctx, "Process already exited, session cleaned up.")
    end

    def handle_cd(ctx)
      cleaned = ctx.arg.to_s.strip
      if cleaned.empty?
        post_reply(ctx, ":x: Usage: `!cd <path>`")
        return
      end

      expanded = File.expand_path(cleaned)
      if Dir.exist?(expanded)
        @working_dirs[ctx.thread_id] = expanded
        post_reply(ctx, ":file_folder: Working directory set to `#{expanded}` (applies to next new session)")
      else
        post_reply(ctx, ":x: Directory not found: `#{expanded}`")
      end
    end

    def handle_heartbeats(ctx)
      unless @heartbeat_scheduler
        post_reply(ctx, "Heartbeat scheduler not configured.")
        return
      end

      statuses = @heartbeat_scheduler.status
      if statuses.empty?
        post_reply(ctx, "No heartbeats configured.")
        return
      end

      post_reply(ctx, format_heartbeats(statuses))
    end

    def handle_usage(ctx)
      post_reply(ctx, ":hourglass: Fetching usage data (takes ~15s)...")

      Thread.new do
        data = fetch_usage_data
        message = data ? format_usage(data) : ":x: Failed to fetch usage data."
        post_reply(ctx, message)
      rescue StandardError => error
        msg = error.message
        log(:error, "Usage command error: #{msg}")
        post_reply(ctx, ":x: Error fetching usage: #{msg}")
      end
    end

    def fetch_usage_data
      output, status = Open3.capture2(USAGE_SCRIPT, "--json", err: File::NULL)
      return nil unless status.success?

      JSON.parse(output)
    rescue JSON::ParserError
      nil
    end

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

    def handle_context(ctx)
      sid = @session_manager.claude_session_id_for(ctx.thread_id)
      unless sid
        post_reply(ctx, "No session found for this thread.")
        return
      end

      post_reply(ctx, ":hourglass: Fetching context data (takes ~20s)...")

      Thread.new do
        data = fetch_context_data(sid)
        message = data ? format_context(data) : ":x: Failed to fetch context data."
        post_reply(ctx, message)
      rescue StandardError => error
        msg = error.message
        log(:error, "Context command error: #{msg}")
        post_reply(ctx, ":x: Error fetching context: #{msg}")
      end
    end

    def fetch_context_data(session_id)
      output, status = Open3.capture2(CONTEXT_SCRIPT, session_id, "--json", err: File::NULL)
      return nil unless status.success?

      JSON.parse(output)
    rescue JSON::ParserError
      nil
    end

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

    def format_context_category(lines, cats, key, label)
      cat = cats[key]
      tokens = cat&.fetch("tokens", nil)
      return unless tokens

      pct_val = cat["percent"]
      pct = pct_val ? " (#{pct_val})" : ""
      lines << "- **#{label}:** #{tokens} tokens#{pct}"
    end

    def format_heartbeats(statuses)
      lines = [
        "#### 🫀 Heartbeat Status",
        "| Name | Next Run | Last Run | Runs | Status |",
        "|------|----------|----------|------|--------|"
      ]
      statuses.each { |status| lines << format_heartbeat_row(status) }
      lines.join("\n")
    end

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

    def post_reply(ctx, message)
      @mattermost.create_post(channel_id: ctx.channel_id, message: message, root_id: ctx.thread_id)
    end

    def cleanup_and_reply(ctx, message)
      @session_manager.stop_session(ctx.thread_id)
      post_reply(ctx, message)
    end

    # -- Tmux session handlers ------------------------------------------------

    def handle_sessions(ctx)
      unless @tmux.available?
        post_reply(ctx, ":x: tmux is not installed.")
        return
      end

      panes = @tmux.list_all_panes
      if panes.empty?
        post_reply(ctx, "No tmux sessions running.")
        return
      end

      claude_panes = panes.select { |pane| @tmux.claude_on_tty?(pane[:tty]) }
      if claude_panes.empty?
        post_reply(ctx, "No Claude sessions found across #{panes.size} tmux panes.")
        return
      end

      lines = [
        "#### :computer: Claude Sessions (#{claude_panes.size})",
        "| Pane | Project | Status |",
        "|------|---------|--------|"
      ]
      claude_panes.each { |pane| lines << format_claude_pane_row(pane) }
      post_reply(ctx, lines.join("\n"))
    end

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
    def detect_pane_status(target)
      output = @tmux.capture_pane(target, lines: 20)
      return :permission if output.include?("Do you want to proceed?")
      return :active if output.include?("esc to interrupt")

      :idle
    rescue Tmux::Error => error
      log(:debug, "detect_pane_status failed for #{target}: #{error.message}")
      :idle
    end

    def handle_session_show(ctx)
      with_tmux_session(ctx) do
        output = @tmux.capture_pane(ctx.arg)
        truncated = truncate_output(output)
        post_reply(ctx, "#### :computer: `#{ctx.arg}` pane output\n```\n#{truncated}\n```")
      end
    end

    def handle_session_status(ctx)
      with_tmux_session(ctx) do
        output = @tmux.capture_pane(ctx.arg, lines: 200)
        truncated = truncate_output(output, 3000)
        post_reply(ctx, "#### :mag: `#{ctx.arg}` status\n```\n#{truncated}\n```\n_AI summary not yet implemented._")
      end
    end

    def handle_session_input(ctx)
      with_tmux_session(ctx) do
        @tmux.send_keys(ctx.arg, ctx.args[1])
        post_reply(ctx, ":keyboard: Sent to `#{ctx.arg}`: `#{ctx.args[1]}`")
      end
    end

    def handle_session_nudge(ctx)
      with_tmux_session(ctx) do
        @tmux.send_keys(ctx.arg, "Are you stuck? What's your current status?")
        post_reply(ctx, ":wave: Nudged `#{ctx.arg}`.")
      end
    end

    def handle_session_approve(ctx)
      with_tmux_session(ctx) do
        @tmux.send_keys_raw(ctx.arg, "Enter")
        post_reply(ctx, ":white_check_mark: Approved permission on `#{ctx.arg}`.")
      end
    end

    def handle_session_deny(ctx)
      with_tmux_session(ctx) do
        @tmux.send_keys_raw(ctx.arg, "Escape")
        post_reply(ctx, ":no_entry_sign: Denied permission on `#{ctx.arg}`.")
      end
    end

    def handle_session_kill(ctx)
      @tmux.kill_session(ctx.arg)
      @tmux_store&.delete(ctx.arg)
      post_reply(ctx, ":skull: Tmux session `#{ctx.arg}` killed.")
    rescue Tmux::NotFound
      @tmux_store&.delete(ctx.arg)
      post_reply(ctx, ":x: Session `#{ctx.arg}` not found (cleaned up store).")
    rescue Tmux::Error => error
      post_reply(ctx, ":x: Error killing session: #{error.message}")
    end

    def handle_spawn(ctx)
      prompt = ctx.arg
      if prompt.to_s.strip.empty?
        post_reply(ctx, ":x: Usage: `!spawn \"prompt\" [--name N] [--dir D]`")
        return
      end

      flags = parse_spawn_flags(ctx.args[1].to_s)
      name = flags[:name] || "earl-#{Time.now.strftime('%Y%m%d%H%M%S')}"
      working_dir = flags[:dir]

      if name.match?(/[.:]/)
        post_reply(ctx, ":x: Invalid session name `#{name}`: cannot contain `.` or `:` (tmux reserved).")
        return
      end

      if working_dir && !Dir.exist?(working_dir)
        post_reply(ctx, ":x: Directory not found: `#{working_dir}`")
        return
      end

      if @tmux.session_exists?(name)
        post_reply(ctx, ":x: Session `#{name}` already exists.")
        return
      end

      spawn_tmux_session(ctx, name: name, prompt: prompt, working_dir: working_dir)
    rescue Tmux::Error => error
      post_reply(ctx, ":x: Failed to spawn session: #{error.message}")
    end

    def spawn_tmux_session(ctx, name:, prompt:, working_dir:)
      command = "claude #{Shellwords.shellescape(prompt)}"
      @tmux.create_session(name: name, command: command, working_dir: working_dir)

      if @tmux_store
        info = TmuxSessionStore::TmuxSessionInfo.new(
          name: name, channel_id: ctx.channel_id, thread_id: ctx.thread_id,
          working_dir: working_dir, prompt: prompt, created_at: Time.now.iso8601
        )
        @tmux_store.save(info)
      end

      post_reply(ctx,
                 ":rocket: Spawned tmux session `#{name}`\n" \
                 "- **Prompt:** #{prompt}\n" \
                 "- **Dir:** #{working_dir || Dir.pwd}\n" \
                 "Use `!session #{name}` to check output.")
    end

    def truncate_output(output, max_length = 3500)
      output.length > max_length ? "…#{output[-max_length..]}" : output
    end

    def with_tmux_session(ctx)
      yield
    rescue Tmux::NotFound
      post_reply(ctx, ":x: Session `#{ctx.arg}` not found.")
    rescue Tmux::Error => error
      post_reply(ctx, ":x: Error: #{error.message}")
    end

    def parse_spawn_flags(str)
      {
        dir: str[/--dir\s+(\S+)/, 1],
        name: str[/--name\s+(\S+)/, 1]
      }.compact
    end
  end
end
