# frozen_string_literal: true

module Earl
  # Manages a single Claude CLI subprocess, handling JSON-stream I/O
  # and emitting text/completion callbacks as responses arrive.
  # :reek:TooManyInstanceVariables
  # :reek:TooManyMethods
  class ClaudeSession
    include Logging
    attr_reader :session_id, :total_cost

    # :reek:ControlParameter
    def initialize(session_id: nil)
      @session_id = session_id || SecureRandom.uuid
      @process = nil
      @stdin = nil
      @reader_thread = nil
      @stderr_thread = nil
      @wait_thread = nil
      @on_text = nil
      @on_complete = nil
      @total_cost = 0.0
      @mutex = Mutex.new
    end

    def on_text(&block)
      @on_text = block
    end

    def on_complete(&block)
      @on_complete = block
    end

    # :reek:TooManyStatements
    def start
      @stdin, stdout, stderr, @wait_thread = Open3.popen3(*cli_args)
      @process = @wait_thread

      log(:info, "Spawning Claude session #{@session_id} — resume with: claude --resume #{@session_id}")

      @reader_thread = Thread.new { read_stdout(stdout) }
      @stderr_thread = Thread.new { read_stderr(stderr) }
    end

    def send_message(text)
      return unless alive?

      payload = JSON.generate({ type: "user", message: { role: "user", content: text } }) + "\n"
      @mutex.synchronize { write_stdin(payload) }

      log(:debug, "Sent message to Claude #{short_id}: #{text[0..60]}")
    end

    def alive?
      @process&.alive?
    end

    # :reek:TooManyStatements
    def kill
      return unless @process

      log(:info, "Killing Claude session #{short_id} (pid=#{@process.pid})")
      terminate_process
      close_stdin
      @reader_thread&.join(3)
      @stderr_thread&.join(1)
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

    def write_stdin(payload)
      @stdin.write(payload)
      @stdin.flush
    end

    # :reek:TooManyStatements
    # :reek:DuplicateMethodCall
    def terminate_process
      pid = @process.pid
      Process.kill("INT", pid)
      sleep 0.1
      Process.kill("INT", pid) if @process.alive?
      sleep 2
      Process.kill("TERM", pid) if @process.alive?
    rescue Errno::ESRCH
      # Process already gone
    end

    def close_stdin
      @stdin&.close
    rescue IOError
      # Already closed
    end

    # :reek:TooManyStatements
    def read_stdout(stdout)
      stdout.each_line do |line|
        line = line.strip
        next if line.empty?

        event = parse_json(line)
        handle_event(event) if event
      end
    rescue IOError
      log(:debug, "Claude stdout stream closed (session #{short_id})")
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

    # :reek:FeatureEnvy
    def handle_event(event)
      case event["type"]
      when "system"
        log(:debug, "Claude system: #{event['subtype']}")
      when "assistant"
        handle_assistant_event(event)
      when "result"
        handle_result_event(event)
      end
    end

    # :reek:TooManyStatements
    # :reek:FeatureEnvy
    def handle_assistant_event(event)
      content = event.dig("message", "content")
      return unless content.is_a?(Array)

      text = content
        .select { |content_block| content_block["type"] == "text" }
        .map { |content_block| content_block["text"] }
        .join

      @on_text&.call(text) unless text.empty?
    end

    def handle_result_event(event)
      cost = event["total_cost_usd"]
      @total_cost = cost if cost
      log(:info, "Claude result: cost=$#{cost} subtype=#{event['subtype']}")
      @on_complete&.call(self)
    end
  end
end
