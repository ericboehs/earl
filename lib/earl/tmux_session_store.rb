# frozen_string_literal: true

module Earl
  # Tracks EARL-spawned tmux sessions with metadata for monitoring and control.
  # Persists to <config_root>/tmux_sessions.json with thread-safe atomic writes.
  class TmuxSessionStore
    include Logging

    # Holds metadata for an EARL-spawned tmux session.
    TmuxSessionInfo = Struct.new(:name, :channel_id, :thread_id, :working_dir,
                                 :prompt, :created_at, keyword_init: true)

    def self.default_path
      @default_path ||= File.join(Earl.config_root, "tmux_sessions.json")
    end

    def initialize(path: self.class.default_path)
      @path = path
      @mutex = Mutex.new
      @cache = nil
      @dirty = false
    end

    def save(info)
      @mutex.synchronize do
        ensure_cache[info.name] = info
        write_store(@cache)
      end
    end

    def get(name)
      @mutex.synchronize { ensure_cache[name] }
    end

    def all
      @mutex.synchronize { ensure_cache.dup }
    end

    def delete(name)
      @mutex.synchronize do
        ensure_cache.delete(name)
        write_store(@cache)
      end
    end

    # Returns names of dead sessions without modifying the store.
    def cleanup
      find_dead_sessions
    end

    # Removes entries for tmux sessions that no longer exist.
    # Shell calls happen outside the mutex to avoid blocking other operations
    # if tmux is slow or hung.
    def cleanup!
      dead = find_dead_sessions
      return dead if dead.empty?

      remove_dead_sessions(dead)
    end

    private

    def find_dead_sessions
      names = @mutex.synchronize { ensure_cache.keys }
      names.reject { |name| Tmux.session_exists?(name) }
    end

    def remove_dead_sessions(dead)
      @mutex.synchronize do
        dead.each { |name| @cache&.delete(name) }
        write_store(@cache) if @cache
        dead
      end
    end

    def ensure_cache
      @cache ||= read_store
      write_store(@cache) if @dirty && @cache
      @cache
    end

    def read_store
      return {} unless File.exist?(@path)

      raw = JSON.parse(File.read(@path))
      deserialize_entries(raw)
    rescue JSON::ParserError, ArgumentError, Errno::ENOENT => error
      file_missing = error.is_a?(Errno::ENOENT)
      backup_corrupted_store unless file_missing
      suffix = file_missing ? "" : " (backed up corrupted file)"
      log(:warn, "Failed to read tmux session store: #{error.message}#{suffix}")
      {}
    end

    def deserialize_entries(raw)
      valid_keys = TmuxSessionInfo.members.map(&:to_s)
      raw.transform_values do |value|
        filtered = value.slice(*valid_keys).transform_keys(&:to_sym)
        TmuxSessionInfo.new(**filtered)
      end
    end

    def backup_corrupted_store
      return unless File.exist?(@path)

      backup_path = "#{@path}.corrupt.#{Time.now.strftime("%Y%m%d%H%M%S")}"
      FileUtils.cp(@path, backup_path)
    rescue StandardError => error
      log(:warn, "Failed to back up corrupted store: #{error.message}")
    end

    def write_store(data)
      serialize_and_write(data)
      @dirty = false
    rescue StandardError => error
      @dirty = true
      log(:error, "Failed to write tmux session store: #{error.message} (will retry on next write)")
    end

    def serialize_and_write(data)
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir)

      serialized = data.transform_values(&:to_h)
      tmp_path = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp_path, JSON.pretty_generate(serialized))
      File.rename(tmp_path, @path)
    rescue StandardError
      FileUtils.rm_f(tmp_path) if tmp_path
      raise
    end
  end
end
