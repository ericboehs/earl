# frozen_string_literal: true

module Earl
  # Persists session metadata to <config_root>/sessions.json for
  # resuming sessions across EARL restarts. Uses an in-memory cache
  # to avoid re-reading from disk on every save, preventing race
  # conditions between concurrent save/touch calls.
  class SessionStore
    include Logging

    # Snapshot of a Claude session's metadata for disk persistence and resume.
    PersistedSession = Struct.new(:claude_session_id, :channel_id, :working_dir,
                                  :started_at, :last_activity_at, :is_paused,
                                  :message_count, :total_cost, :total_input_tokens,
                                  :total_output_tokens, keyword_init: true)

    def self.default_path
      @default_path ||= File.join(Earl.config_root, "sessions.json")
    end

    def initialize(path: self.class.default_path)
      @path = path
      @mutex = Mutex.new
      @ensure_cache = nil # Lazy-loaded from disk on first access
    end

    def load
      @mutex.synchronize { ensure_cache.dup }
    end

    def save(thread_id, persisted_session)
      @mutex.synchronize do
        ensure_cache[thread_id] = persisted_session
        write_store(@ensure_cache)
      end
    end

    def remove(thread_id)
      @mutex.synchronize do
        ensure_cache.delete(thread_id)
        write_store(@ensure_cache)
      end
    end

    def touch(thread_id)
      @mutex.synchronize do
        session = ensure_cache[thread_id]
        if session
          session.last_activity_at = Time.now.iso8601
          write_store(@ensure_cache)
        end
      end
    end

    private

    def ensure_cache
      @ensure_cache ||= read_store
    end

    def read_store
      return {} unless File.exist?(@path)

      raw = JSON.parse(File.read(@path))
      raw.transform_values { |attrs| PersistedSession.new(**attrs.transform_keys(&:to_sym)) }
    rescue JSON::ParserError, Errno::ENOENT => error
      log(:warn, "Failed to read session store: #{error.message}")
      {}
    end

    def write_store(data)
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir)

      serialized = data.transform_values(&:to_h)
      tmp_path = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp_path, JSON.pretty_generate(serialized))
      File.rename(tmp_path, @path)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ENOSPC, IOError => error
      log(:error, "Failed to write session store: #{error.message}")
      FileUtils.rm_f(tmp_path) if tmp_path
    end
  end
end
