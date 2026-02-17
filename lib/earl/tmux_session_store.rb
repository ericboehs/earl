# frozen_string_literal: true

module Earl
  # Tracks EARL-spawned tmux sessions with metadata for monitoring and control.
  # Persists to ~/.config/earl/tmux_sessions.json with thread-safe atomic writes.
  class TmuxSessionStore
    include Logging

    # Holds metadata for an EARL-spawned tmux session.
    TmuxSessionInfo = Struct.new(:name, :channel_id, :thread_id, :working_dir,
                                  :prompt, :created_at, keyword_init: true)

    DEFAULT_PATH = File.expand_path("~/.config/earl/tmux_sessions.json")

    def initialize(path: DEFAULT_PATH)
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

    # Removes entries for tmux sessions that no longer exist.
    # Shell calls happen outside the mutex to avoid blocking other operations
    # if tmux is slow or hung.
    def cleanup!
      names = @mutex.synchronize { ensure_cache.keys }
      dead = names.reject { |name| Tmux.session_exists?(name) }
      return dead if dead.empty?

      @mutex.synchronize do
        dead.each { |name| @cache&.delete(name) }
        write_store(@cache) if @cache
        dead
      end
    end

    private

    def ensure_cache
      @cache ||= read_store
      write_store(@cache) if @dirty && @cache
      @cache
    end

    def read_store
      return {} unless File.exist?(@path)

      raw = JSON.parse(File.read(@path))
      valid_keys = TmuxSessionInfo.members.map(&:to_s)
      raw.transform_values do |value|
        filtered = value.slice(*valid_keys).transform_keys(&:to_sym)
        TmuxSessionInfo.new(**filtered)
      end
    rescue JSON::ParserError, ArgumentError => error
      backup_corrupted_store
      log(:warn, "Failed to read tmux session store: #{error.message} (backed up corrupted file)")
      {}
    rescue Errno::ENOENT => error
      log(:warn, "Failed to read tmux session store: #{error.message}")
      {}
    end

    def backup_corrupted_store
      return unless File.exist?(@path)

      backup_path = "#{@path}.corrupt.#{Time.now.strftime('%Y%m%d%H%M%S')}"
      FileUtils.cp(@path, backup_path)
    rescue StandardError => error
      log(:warn, "Failed to back up corrupted store: #{error.message}")
    end

    def write_store(data)
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

      serialized = data.transform_values(&:to_h)
      tmp_path = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp_path, JSON.pretty_generate(serialized))
      File.rename(tmp_path, @path)
      @dirty = false
    rescue StandardError => error
      @dirty = true
      log(:error, "Failed to write tmux session store: #{error.message} (will retry on next write)")
      FileUtils.rm_f(tmp_path) if tmp_path
    end
  end
end
