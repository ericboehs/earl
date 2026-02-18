# frozen_string_literal: true

module Earl
  # Manages a single Claude CLI subprocess, handling JSON-stream I/O
  # and emitting text/completion callbacks as responses arrive.
  class ClaudeSession
    include Logging
    attr_reader :session_id

    def process_pid
      @runtime.process_state.process&.pid
    end

    # Tracks the Claude CLI subprocess and its I/O threads.
    ProcessState = Struct.new(:process, :stdin, :reader_thread, :stderr_thread, :wait_thread, keyword_init: true) do
      def write(payload)
        stdin.write(payload)
        stdin.flush
      end

      def join_io_threads
        reader_thread&.join(3)
        stderr_thread&.join(1)
      end
    end
    # Holds text-streaming, tool-use, and completion callback procs.
    Callbacks = Struct.new(:on_text, :on_complete, :on_tool_use, :on_system, keyword_init: true)
    # Groups session launch options to keep instance variable count low.
    Options = Struct.new(:permission_config, :resume, :working_dir, :username, :mcp_config_path, keyword_init: true)
    # Groups mutable runtime state: subprocess, callbacks, and mutex.
    RuntimeState = Struct.new(:process_state, :callbacks, :mutex, keyword_init: true)

    # Tracks usage statistics, timing, and cost across the session.
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

      def begin_turn
        reset_turn
        self.message_sent_at = Time.now
      end

      def format_summary(prefix)
        parts = [ "#{prefix}:", format_token_stats, *format_timing_stats ]
        parts << "model=#{model_id}" if model_id
        parts.join(" | ")
      end

      def format_token_stats
        total = total_input_tokens + total_output_tokens
        "#{total} tokens (turn: in:#{turn_input_tokens} out:#{turn_output_tokens})"
      end

      def format_timing_stats
        parts = []
        pct = context_percent
        parts << format("%.0f%% context", pct) if pct
        ttft = time_to_first_token
        parts << format("TTFT: %.1fs", ttft) if ttft
        tps = tokens_per_second
        parts << format("%.0f tok/s", tps) if tps
        parts
      end
    end

    def initialize(session_id: SecureRandom.uuid, permission_config: nil, mode: :new, working_dir: nil, username: nil)
      @session_id = session_id
      @options = Options.new(
        permission_config: permission_config, resume: mode == :resume,
        working_dir: working_dir, username: username
      )
      @runtime = RuntimeState.new(
        process_state: ProcessState.new, callbacks: Callbacks.new, mutex: Mutex.new
      )
      @stats = Stats.new(
        total_cost: 0.0, total_input_tokens: 0, total_output_tokens: 0,
        turn_input_tokens: 0, turn_output_tokens: 0,
        cache_read_tokens: 0, cache_creation_tokens: 0
      )
    end

    def stats
      @stats
    end

    def on_text(&block)
      @runtime.callbacks.on_text = block
    end

    def on_complete(&block)
      @runtime.callbacks.on_complete = block
    end

    def on_tool_use(&block)
      @runtime.callbacks.on_tool_use = block
    end

    def on_system(&block)
      @runtime.callbacks.on_system = block
    end

    def send_message(text)
      unless alive?
        log(:warn, "Cannot send message to dead session #{short_id} — process not running")
        return false
      end

      write_to_stdin(text)
      @stats.begin_turn
      log(:debug, "Sent message to Claude #{short_id}: #{text[0..60]}")
      true
    rescue IOError, Errno::EPIPE => error
      log(:error, "Failed to write to Claude #{short_id}: #{error.message}")
      false
    end

    private

    def write_to_stdin(text)
      payload = JSON.generate({ type: "user", message: { role: "user", content: text } }) + "\n"
      @runtime.mutex.synchronize { @runtime.process_state.write(payload) }
    end

    def short_id
      @session_id[0..7]
    end

    # Process lifecycle management: start, kill, and signal handling.
    module ProcessManagement
      def start
        stdin, stdout, stderr, wait_thread = open_process
        @runtime.process_state = ProcessState.new(process: wait_thread, stdin: stdin, wait_thread: wait_thread)

        log(:info, "Spawning Claude session #{@session_id} — resume with: claude --resume #{@session_id}")
        spawn_io_threads(stdout, stderr)
      end

      def alive?
        @runtime.process_state.process&.alive?
      end

      def kill
        return unless (process = @runtime.process_state.process)

        log(:info, "Killing Claude session #{short_id} (pid=#{process.pid})")
        terminate_process
        close_stdin
        join_threads
      end

      private

      def open_process
        working_dir = @options.working_dir
        popen_opts = working_dir ? { chdir: working_dir } : {}
        env = { "TMUX" => nil, "TMUX_PANE" => nil }
        Open3.popen3(env, *cli_args, **popen_opts)
      end

      def join_threads
        @runtime.process_state.join_io_threads
      end

      def terminate_process
        pid = @runtime.process_state.process.pid
        Process.kill("INT", pid)
        sleep 0.1
        escalate_signal(pid)
      rescue Errno::ESRCH
        # Process already gone
      end

      def escalate_signal(pid)
        2.times do
          return unless @runtime.process_state.process.alive?
          sleep 1
        end
        Process.kill("TERM", pid)
      rescue Errno::ESRCH
        # Process exited between alive? check and kill
      end

      def close_stdin
        @runtime.process_state.stdin&.close
      rescue IOError
        # Already closed
      end
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
        @options.mcp_config_path ||= write_mcp_config
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
        json = JSON.generate(config)
        File.open(path, File::CREAT | File::EXCL | File::WRONLY, 0o600) do |file|
          file.write(json)
        end
        path
      rescue Errno::EEXIST
        write_file_securely(path, json)
        path
      end

      def write_file_securely(path, content)
        File.open(path, File::WRONLY | File::TRUNC, 0o600) { |file| file.write(content) }
      end
    end

    # Event/IO processing methods extracted to reduce class method count.
    module EventProcessing
      private

      def spawn_io_threads(stdout, stderr)
        ps = @runtime.process_state
        ps.reader_thread = Thread.new { read_stdout(stdout) }
        ps.stderr_thread = Thread.new { read_stderr(stderr) }
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
        subtype = event["subtype"]
        log(:debug, "Claude system: #{subtype}")
        message = event["message"]
        @runtime.callbacks.on_system&.call(subtype: subtype, message: message) if message
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
        @runtime.callbacks.on_text&.call(text)
      end

      def emit_tool_use_blocks(content)
        content.each do |item|
          emit_single_tool_use(item) if item["type"] == "tool_use"
        end
      end

      def emit_single_tool_use(item)
        tool_id, tool_name, tool_input = item.values_at("id", "name", "input")
        @runtime.callbacks.on_tool_use&.call(id: tool_id, name: tool_name, input: tool_input)
      end

      def handle_result_event(event)
        @stats.complete_at = Time.now
        update_stats_from_result(event)
        log(:info, format_result_log)
        @runtime.callbacks.on_complete&.call(self)
      end

      def update_stats_from_result(event)
        cost = event["total_cost_usd"]
        @stats.total_cost = cost if cost
        extract_usage(event["usage"])
        extract_model_usage(event["modelUsage"])
      end

      def extract_usage(usage)
        return unless usage.is_a?(Hash)

        input, output, cache_read, cache_create = usage.values_at(
          "input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"
        )
        @stats.turn_input_tokens = input || 0
        @stats.turn_output_tokens = output || 0
        @stats.cache_read_tokens = cache_read || 0
        @stats.cache_creation_tokens = cache_create || 0
      end

      def extract_model_usage(model_usage)
        return unless model_usage.is_a?(Hash)

        apply_hash_entries(model_usage)
      end

      def apply_hash_entries(model_usage)
        entries = model_usage.select { |_, val| val.is_a?(Hash) }
        apply_primary_model_stats(entries) unless entries.empty?
      end

      def apply_primary_model_stats(entries)
        primary_id, primary_data = entries.max_by { |_, data| data["contextWindow"] || 0 }
        apply_model_stats(primary_id, primary_data, entries)
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
        model = @stats.model_id
        parts = [
          "Claude result:",
          format_token_counts,
          format_context_usage,
          format_timing,
          format_cost,
          ("model=#{model}" if model)
        ]
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

    include ProcessManagement
    include CliArgBuilder
    include EventProcessing
  end
end
