# frozen_string_literal: true

module Earl
  # Manages a single Claude CLI subprocess, handling JSON-stream I/O
  # and emitting text/completion callbacks as responses arrive.
  class ClaudeSession
    include Logging
    attr_reader :session_id

    def process_pid
      @process_state.process&.pid
    end

    # Tracks the Claude CLI subprocess and its I/O threads.
    ProcessState = Struct.new(:process, :stdin, :reader_thread, :stderr_thread, :wait_thread, keyword_init: true) do
      def write(payload)
        stdin.write(payload)
        stdin.flush
      end
    end
    # Holds text-streaming and completion callback procs.
    Callbacks = Struct.new(:on_text, :on_complete, :on_tool_use, keyword_init: true)
    # Groups session launch options to keep instance variable count low.
    Options = Struct.new(:permission_config, :resume, :working_dir, :username, keyword_init: true)

    # Tracks usage statistics, timing, and cost across the session.
    # rubocop:disable Metrics/BlockLength
    Stats = Struct.new(
      :total_cost, :total_input_tokens, :total_output_tokens,
      :turn_input_tokens, :turn_output_tokens,
      :cache_read_tokens, :cache_creation_tokens,
      :context_window, :model_id,
      :message_sent_at, :first_token_at, :complete_at,
      keyword_init: true
    ) do
      def time_to_first_token
        return nil unless message_sent_at && first_token_at

        first_token_at - message_sent_at
      end

      def tokens_per_second
        return nil unless first_token_at && complete_at && turn_output_tokens&.positive?

        duration = complete_at - first_token_at
        return nil unless duration.positive?

        turn_output_tokens / duration
      end

      def context_percent
        return nil unless context_window&.positive?

        context_tokens = turn_input_tokens + cache_read_tokens + cache_creation_tokens
        return nil unless context_tokens.positive?

        (context_tokens.to_f / context_window * 100)
      end

      def reset_turn
        self.turn_input_tokens = 0
        self.turn_output_tokens = 0
        self.cache_read_tokens = 0
        self.cache_creation_tokens = 0
        self.message_sent_at = nil
        self.first_token_at = nil
        self.complete_at = nil
      end

      def format_summary(prefix)
        parts = [ "#{prefix}:" ]
        total = total_input_tokens + total_output_tokens
        parts << "#{total} tokens (turn: in:#{turn_input_tokens} out:#{turn_output_tokens})"
        pct = context_percent
        parts << format("%.0f%% context", pct) if pct
        ttft = time_to_first_token
        parts << format("TTFT: %.1fs", ttft) if ttft
        tps = tokens_per_second
        parts << format("%.0f tok/s", tps) if tps
        parts << "model=#{model_id}" if model_id
        parts.join(" | ")
      end
    end
    # rubocop:enable Metrics/BlockLength

    def initialize(session_id: SecureRandom.uuid, permission_config: nil, mode: :new, working_dir: nil, username: nil)
      @session_id = session_id
      @options = Options.new(
        permission_config: permission_config, resume: mode == :resume,
        working_dir: working_dir, username: username
      )
      @process_state = ProcessState.new
      @callbacks = Callbacks.new
      @stats = Stats.new(
        total_cost: 0.0, total_input_tokens: 0, total_output_tokens: 0,
        turn_input_tokens: 0, turn_output_tokens: 0,
        cache_read_tokens: 0, cache_creation_tokens: 0
      )
      @mutex = Mutex.new
    end

    def stats
      @stats
    end

    def total_cost
      @stats.total_cost
    end

    def on_text(&block)
      @callbacks.on_text = block
    end

    def on_complete(&block)
      @callbacks.on_complete = block
    end

    def on_tool_use(&block)
      @callbacks.on_tool_use = block
    end

    def start
      stdin, stdout, stderr, wait_thread = open_process
      @process_state = ProcessState.new(process: wait_thread, stdin: stdin, wait_thread: wait_thread)

      log(:info, "Spawning Claude session #{@session_id} — resume with: claude --resume #{@session_id}")
      spawn_io_threads(stdout, stderr)
    end

    def send_message(text)
      unless alive?
        log(:warn, "Cannot send message to dead session #{short_id} — process not running")
        return
      end

      @stats.reset_turn
      @stats.message_sent_at = Time.now

      payload = JSON.generate({ type: "user", message: { role: "user", content: text } }) + "\n"
      @mutex.synchronize { @process_state.write(payload) }

      log(:debug, "Sent message to Claude #{short_id}: #{text[0..60]}")
    end

    def alive?
      @process_state.process&.alive?
    end

    def kill
      return unless (process = @process_state.process)

      log(:info, "Killing Claude session #{short_id} (pid=#{process.pid})")
      terminate_process
      close_stdin
      join_threads
    end

    private

    def short_id
      @session_id[0..7]
    end

    def open_process
      working_dir = @options.working_dir
      popen_opts = working_dir ? { chdir: working_dir } : {}
      env = { "TMUX" => nil, "TMUX_PANE" => nil }
      Open3.popen3(env, *cli_args, **popen_opts)
    end

    def join_threads
      @process_state.reader_thread&.join(3)
      @process_state.stderr_thread&.join(1)
    end

    def terminate_process
      pid = @process_state.process.pid
      Process.kill("INT", pid)
      sleep 0.1
      escalate_signal(pid)
    rescue Errno::ESRCH
      # Process already gone
    end

    def escalate_signal(pid)
      2.times do
        return unless @process_state.process.alive?
        sleep 1
      end
      Process.kill("TERM", pid)
    rescue Errno::ESRCH
      # Process exited between alive? check and kill
    end

    def close_stdin
      @process_state.stdin&.close
    rescue IOError
      # Already closed
    end

    # Builds the CLI argument list for spawning the Claude process.
    module CliArgBuilder
      private

      def cli_args
        [ "claude", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         *session_args, *permission_args, *system_prompt_args ]
      end

      def session_args
        @options.resume ? [ "--resume", @session_id ] : [ "--session-id", @session_id ]
      end

      def permission_args
        return [ "--dangerously-skip-permissions" ] unless @options.permission_config

        [ "--permission-prompt-tool", "mcp__earl__permission_prompt",
         "--mcp-config", mcp_config_path ]
      end

      def system_prompt_args
        prompt = Memory::PromptBuilder.new(store: Memory::Store.new).build
        prompt ? [ "--append-system-prompt", prompt ] : []
      end

      def mcp_config_path
        @mcp_config_path ||= write_mcp_config
      end

      def write_mcp_config
        config = {
          mcpServers: {
            earl: {
              command: File.expand_path("../../bin/earl-permission-server", __dir__),
              args: [],
              env: @options.permission_config.merge(
                "EARL_CURRENT_USERNAME" => @options.username || ""
              )
            }
          }
        }
        path = File.join(Dir.tmpdir, "earl-mcp-#{@session_id}.json")
        File.write(path, JSON.generate(config))
        File.chmod(0o600, path)
        path
      end
    end

    include CliArgBuilder

    # Event/IO processing methods extracted to reduce class method count.
    module EventProcessing
      private

      def spawn_io_threads(stdout, stderr)
        @process_state.reader_thread = Thread.new { read_stdout(stdout) }
        @process_state.stderr_thread = Thread.new { read_stderr(stderr) }
      end

      def read_stdout(stdout)
        stdout.each_line do |line|
          process_line(line.strip)
        end
      rescue IOError
        log(:debug, "Claude stdout stream closed (session #{short_id})")
      end

      def process_line(line)
        return if line.empty?

        event = parse_json(line)
        handle_event(event) if event
      end

      def parse_json(line)
        JSON.parse(line)
      rescue JSON::ParserError => error
        log(:warn, "Unparsable Claude stdout (session #{short_id}): #{line[0..200]} — #{error.message}")
        nil
      end

      def read_stderr(stderr)
        stderr.each_line do |line|
          log(:debug, "Claude stderr: #{line.strip}")
        end
      rescue IOError
        log(:debug, "Claude stderr stream closed (session #{short_id})")
      end

      def handle_event(event)
        case event["type"]
        when "system" then handle_system_event(event)
        when "assistant" then handle_assistant_event(event)
        when "result" then handle_result_event(event)
        end
      end

      def handle_system_event(event)
        log(:debug, "Claude system: #{event['subtype']}")
      end

      def handle_assistant_event(event)
        content = event.dig("message", "content")
        return unless content.is_a?(Array)

        emit_text_content(content)
        emit_tool_use_blocks(content)
      end

      def emit_text_content(content)
        text = content.filter_map { |item| item["text"] if item["type"] == "text" }.join
        return if text.empty?

        @stats.first_token_at ||= Time.now
        @callbacks.on_text&.call(text)
      end

      def emit_tool_use_blocks(content)
        content.each do |item|
          next unless item["type"] == "tool_use"

          @callbacks.on_tool_use&.call(id: item["id"], name: item["name"], input: item["input"])
        end
      end

      def handle_result_event(event)
        @stats.complete_at = Time.now
        update_stats_from_result(event)
        log(:info, format_result_log)
        @callbacks.on_complete&.call(self)
      end

      def update_stats_from_result(event)
        cost = event["total_cost_usd"]
        @stats.total_cost = cost if cost
        extract_usage(event["usage"])
        extract_model_usage(event["modelUsage"])
      end

      # :reek:FeatureEnvy
      def extract_usage(usage)
        return unless usage.is_a?(Hash)

        @stats.turn_input_tokens = usage["input_tokens"] || 0
        @stats.turn_output_tokens = usage["output_tokens"] || 0
        @stats.cache_read_tokens = usage["cache_read_input_tokens"] || 0
        @stats.cache_creation_tokens = usage["cache_creation_input_tokens"] || 0
      end

      # :reek:FeatureEnvy
      def extract_model_usage(model_usage)
        return unless model_usage.is_a?(Hash)

        hash_entries = model_usage.select { |_, data| data.is_a?(Hash) }
        return if hash_entries.empty?

        primary_id, primary_data = hash_entries.max_by { |_, data| data["contextWindow"] || 0 }
        apply_model_stats(primary_id, primary_data, hash_entries)
      end

      def apply_model_stats(model_id, primary_data, entries)
        @stats.model_id = model_id
        totals = entries.each_with_object({ input: 0, output: 0 }) do |(_, data), acc|
          acc[:input] += data["inputTokens"] || 0
          acc[:output] += data["outputTokens"] || 0
        end
        @stats.total_input_tokens = totals[:input]
        @stats.total_output_tokens = totals[:output]
        context = primary_data["contextWindow"]
        @stats.context_window = context if context
      end

      def format_result_log
        parts = [ "Claude result:" ]
        parts << format_token_counts
        parts << format_context_usage
        parts << format_timing
        parts << format_cost
        model = @stats.model_id
        parts << "model=#{model}" if model
        parts.compact.join(" | ")
      end

      def format_token_counts
        turn_in = @stats.turn_input_tokens
        turn_out = @stats.turn_output_tokens
        total = @stats.total_input_tokens + @stats.total_output_tokens
        "#{total} total tokens (turn: in:#{turn_in} out:#{turn_out})"
      end

      def format_context_usage
        pct = @stats.context_percent
        return nil unless pct

        format("%.0f%% context used", pct)
      end

      def format_timing
        ttft = @stats.time_to_first_token
        tps = @stats.tokens_per_second
        parts = []
        parts << format("TTFT: %.1fs", ttft) if ttft
        parts << format("%.0f tok/s", tps) if tps
        parts.empty? ? nil : parts.join(" ")
      end

      def format_cost
        format("cost=$%.4f", @stats.total_cost)
      end
    end

    include EventProcessing
  end
end
