# frozen_string_literal: true

module Earl
  # Persists session metadata to ~/.config/earl/sessions.json for
  # resuming sessions across EARL restarts.
  class SessionStore
    include Logging

    PersistedSession = Struct.new(:claude_session_id, :channel_id, :working_dir,
                                  :started_at, :last_activity_at, :is_paused,
                                  :message_count, keyword_init: true)

    DEFAULT_PATH = File.expand_path("~/.config/earl/sessions.json")

    def initialize(path: DEFAULT_PATH)
      @path = path
      @mutex = Mutex.new
    end

    def load
      @mutex.synchronize { read_store }
    end

    def save(thread_id, persisted_session)
      @mutex.synchronize do
        data = read_store
        data[thread_id] = persisted_session
        write_store(data)
      end
    end

    def remove(thread_id)
      @mutex.synchronize do
        data = read_store
        data.delete(thread_id)
        write_store(data)
      end
    end

    def touch(thread_id)
      @mutex.synchronize do
        data = read_store
        session = data[thread_id]
        if session
          session.last_activity_at = Time.now.iso8601
          write_store(data)
        end
      end
    end

    private

    def read_store
      return {} unless File.exist?(@path)

      raw = JSON.parse(File.read(@path))
      raw.transform_values { |v| PersistedSession.new(**v.transform_keys(&:to_sym)) }
    rescue JSON::ParserError, Errno::ENOENT => error
      log(:warn, "Failed to read session store: #{error.message}")
      {}
    end

    def write_store(data)
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

      serialized = data.transform_values(&:to_h)
      tmp_path = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp_path, JSON.pretty_generate(serialized))
      File.rename(tmp_path, @path)
    rescue StandardError => error
      log(:error, "Failed to write session store: #{error.message}")
      FileUtils.rm_f(tmp_path) if tmp_path
    end
  end
end
