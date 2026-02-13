# frozen_string_literal: true

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
      | `!stop` | Kill current session |
      | `!escape` | Send SIGINT to Claude (interrupt) |
      | `!kill` | Force kill session |
      | `!compact` | Compact Claude's context |
      | `!cd <path>` | Set working directory for next session |
      | `!permissions auto\\|interactive` | Toggle permission mode |
    HELP

    def initialize(session_manager:, mattermost:, config:)
      @session_manager = session_manager
      @mattermost = mattermost
      @config = config
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
