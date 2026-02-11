# frozen_string_literal: true

module Earl
  # Manages a single Claude CLI subprocess, handling JSON-stream I/O
  # and emitting text/completion callbacks as responses arrive.
  class ClaudeSession
    include Logging
    attr_reader :session_id

    # Tracks the Claude CLI subprocess and its I/O threads.
    ProcessState = Struct.new(:process, :stdin, :reader_thread, :stderr_thread, :wait_thread, keyword_init: true) do
      def write(payload)
        stdin.write(payload)
        stdin.flush
      end
    end
    # Holds text-streaming and completion callback procs, plus accumulated cost.
    Callbacks = Struct.new(:on_text, :on_complete, :total_cost, keyword_init: true)

    def initialize(session_id: SecureRandom.uuid)
      @session_id = session_id
      @process_state = ProcessState.new
      @callbacks = Callbacks.new(total_cost: 0.0)
      @mutex = Mutex.new
    end

    def total_cost
      @callbacks.total_cost
    end

    def on_text(&block)
      @callbacks.on_text = block
    end

    def on_complete(&block)
      @callbacks.on_complete = block
    end

    def start
      stdin, stdout, stderr, wait_thread = Open3.popen3(*cli_args)
      @process_state = ProcessState.new(
        process: wait_thread, stdin: stdin, wait_thread: wait_thread
      )

      log(:info, "Spawning Claude session #{@session_id} — resume with: claude --resume #{@session_id}")
      spawn_io_threads(stdout, stderr)
    end

    def send_message(text)
      return unless alive?

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

    def cli_args
      [
        "claude",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--session-id", @session_id,
        "--dangerously-skip-permissions"
      ]
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
        text = extract_text_content(event)
        @callbacks.on_text&.call(text) unless text.empty?
      end

      def extract_text_content(event)
        content = event.dig("message", "content")
        return "" unless content.is_a?(Array)

        content.select { |block| block["type"] == "text" }.map { |block| block["text"] }.join
      end

      def handle_result_event(event)
        cost = event["total_cost_usd"]
        @callbacks.total_cost = cost if cost
        log(:info, "Claude result: cost=$#{cost} subtype=#{event['subtype']}")
        @callbacks.on_complete&.call(self)
      end
    end

    include EventProcessing
  end
end
