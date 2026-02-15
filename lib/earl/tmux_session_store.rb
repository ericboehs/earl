# frozen_string_literal: true

module Earl
  # Tracks EARL-spawned tmux sessions with metadata for monitoring and control.
  # Persists to ~/.config/earl/tmux_sessions.json with thread-safe atomic writes.
  # :reek:MissingSafeMethod
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
    def cleanup!
      @mutex.synchronize do
        dead = ensure_cache.keys.reject { |name| Tmux.session_exists?(name) }
        dead.each { |name| @cache.delete(name) }
        write_store(@cache) if dead.any?
        dead
      end
    end

    private

    def ensure_cache
      @cache ||= read_store
    end

    # :reek:TooManyStatements
    def read_store
      return {} unless File.exist?(@path)

      raw = JSON.parse(File.read(@path))
      valid_keys = TmuxSessionInfo.members.map(&:to_s)
      raw.transform_values do |value|
        filtered = value.slice(*valid_keys).transform_keys(&:to_sym)
        TmuxSessionInfo.new(**filtered)
      end
    rescue JSON::ParserError, ArgumentError, Errno::ENOENT => error
      log(:warn, "Failed to read tmux session store: #{error.message}")
      {}
    end

    # :reek:TooManyStatements
    def write_store(data)
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir) unless Dir.exist?(dir)

      serialized = data.transform_values(&:to_h)
      tmp_path = "#{@path}.tmp.#{Process.pid}"
      File.write(tmp_path, JSON.pretty_generate(serialized))
      File.rename(tmp_path, @path)
    rescue StandardError => error
      log(:error, "Failed to write tmux session store: #{error.message} (in-memory cache may diverge from disk)")
      FileUtils.rm_f(tmp_path) if tmp_path
    end
  end
end
