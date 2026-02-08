# frozen_string_literal: true

module Earl
  class ClaudeSession
    attr_reader :session_id, :total_cost

    def initialize(session_id: nil)
      @session_id = session_id || SecureRandom.uuid
      @process = nil
      @stdin = nil
      @reader_thread = nil
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

    def start
      args = [
        "claude",
        "--input-format", "stream-json",
        "--output-format", "stream-json",
        "--verbose",
        "--session-id", @session_id,
        "--dangerously-skip-permissions"
      ]

      Earl.logger.info "Spawning Claude session #{@session_id} — resume with: claude --resume #{@session_id}"

      @stdin, stdout, stderr, @wait_thread = Open3.popen3(*args)
      @process = @wait_thread

      @reader_thread = Thread.new { read_stdout(stdout) }
      @stderr_thread = Thread.new { read_stderr(stderr) }
    end

    def send_message(text)
      return unless alive?

      msg = JSON.generate({
        type: "user",
        message: { role: "user", content: text }
      }) + "\n"

      @mutex.synchronize do
        @stdin.write(msg)
        @stdin.flush
      end

      Earl.logger.debug "Sent message to Claude #{@session_id[0..7]}: #{text[0..60]}"
    end

    def alive?
      @process&.alive?
    end

    def kill
      return unless @process

      pid = @process.pid
      Earl.logger.info "Killing Claude session #{@session_id[0..7]} (pid=#{pid})"

      begin
        Process.kill("INT", pid)
        sleep 0.1
        Process.kill("INT", pid) if @process.alive?
        sleep 2
        Process.kill("TERM", pid) if @process.alive?
      rescue Errno::ESRCH
        # Process already gone
      end

      begin
        @stdin&.close
      rescue IOError
        # Already closed
      end
      @reader_thread&.join(3)
      @stderr_thread&.join(1)
    end

    private

    def read_stdout(stdout)
      stdout.each_line do |line|
        line = line.strip
        next if line.empty?

        begin
          event = JSON.parse(line)
        rescue JSON::ParserError => e
          Earl.logger.warn "Unparsable Claude stdout (session #{@session_id[0..7]}): #{line[0..200]}"
          next
        end

        handle_event(event)
      end
    rescue IOError
      Earl.logger.debug "Claude stdout stream closed (session #{@session_id[0..7]})"
    end

    def read_stderr(stderr)
      stderr.each_line do |line|
        Earl.logger.debug "Claude stderr: #{line.strip}"
      end
    rescue IOError
      Earl.logger.debug "Claude stderr stream closed (session #{@session_id[0..7]})"
    end

    def handle_event(event)
      case event["type"]
      when "system"
        Earl.logger.debug "Claude system: #{event['subtype']}"
      when "assistant"
        content = event.dig("message", "content")
        return unless content.is_a?(Array)

        text = content
          .select { |c| c["type"] == "text" }
          .map { |c| c["text"] }
          .join

        @on_text&.call(text) unless text.empty?
      when "result"
        cost = event["total_cost_usd"]
        @total_cost = cost if cost
        Earl.logger.info "Claude result: cost=$#{cost} subtype=#{event['subtype']}"
        @on_complete&.call(self)
      end
    end
  end
end
