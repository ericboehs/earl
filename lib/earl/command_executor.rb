# frozen_string_literal: true

require "open3"

module Earl
  # Executes `!` commands parsed by CommandParser, dispatching to the
  # appropriate session manager or mattermost action.
  class CommandExecutor
    include Logging

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
      | `!permissions auto\\|interactive` | Toggle permission mode |
      | `!heartbeats` | Show heartbeat schedule status |
    HELP

    def initialize(session_manager:, mattermost:, config:, heartbeat_scheduler: nil)
      @session_manager = session_manager
      @mattermost = mattermost
      @config = config
      @heartbeat_scheduler = heartbeat_scheduler
      @working_dirs = {} # thread_id -> path
      @permission_modes = {} # thread_id -> :auto | :interactive
    end

    def execute(command, thread_id:, channel_id:)
      arg = command.args.first
      case command.name
      when :help then handle_help(thread_id, channel_id)
      when :stats then handle_stats(thread_id, channel_id)
      when :stop then handle_stop(thread_id, channel_id)
      when :escape then handle_escape(thread_id, channel_id)
      when :kill then handle_kill(thread_id, channel_id)
      when :compact then handle_compact(thread_id)
      when :cd then handle_cd(thread_id, channel_id, arg)
      when :permissions then handle_permissions(thread_id, channel_id, arg)
      when :heartbeats then handle_heartbeats(thread_id, channel_id)
      when :usage then handle_usage(thread_id, channel_id)
      when :context then handle_context(thread_id, channel_id)
      end
    end

    def working_dir_for(thread_id)
      @working_dirs[thread_id]
    end

    def permission_mode_for(thread_id)
      @permission_modes.fetch(thread_id, :interactive)
    end

    private

    def handle_help(thread_id, channel_id)
      post_reply(channel_id, thread_id, HELP_TABLE)
    end

    def handle_stats(thread_id, channel_id)
      session = @session_manager.get(thread_id)
      unless session
        post_reply(channel_id, thread_id, "No active session for this thread.")
        return
      end

      post_reply(channel_id, thread_id, format_stats(session.stats))
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

    def handle_compact(thread_id)
      session = @session_manager.get(thread_id)
      session&.send_message("/compact")
    end

    def handle_cd(thread_id, channel_id, path)
      expanded = File.expand_path(path)
      if Dir.exist?(expanded)
        @working_dirs[thread_id] = expanded
        post_reply(channel_id, thread_id, ":file_folder: Working directory set to `#{expanded}` (applies to next new session)")
      else
        post_reply(channel_id, thread_id, ":x: Directory not found: `#{expanded}`")
      end
    end

    def handle_permissions(thread_id, channel_id, mode)
      @permission_modes[thread_id] = mode.to_sym
      post_reply(channel_id, thread_id, ":lock: Permission mode set to `#{mode}` for this thread.")
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

    USAGE_SCRIPT = File.expand_path("../../bin/claude-usage", __dir__)
    CONTEXT_SCRIPT = File.expand_path("../../bin/claude-context", __dir__)

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
      if session && session["percent_used"]
        lines << "- **Session:** #{session['percent_used']}% used — resets #{session['resets']}"
      end

      week = data["week"]
      if week && week["percent_used"]
        lines << "- **Week:** #{week['percent_used']}% used — resets #{week['resets']}"
      end

      extra = data["extra"]
      if extra && extra["percent_used"]
        lines << "- **Extra:** #{extra['percent_used']}% used (#{extra['spent']} / #{extra['budget']}) — resets #{extra['resets']}"
      end

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

    def format_number(num)
      return "0" unless num

      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end
  end
end
