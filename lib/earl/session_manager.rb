# frozen_string_literal: true

module Earl
  # Thread-safe registry of active Claude sessions, keyed by Mattermost
  # thread ID, with lazy creation, coordinated shutdown, and optional persistence.
  class SessionManager
    include Logging

    def initialize(config: nil, session_store: nil)
      @config = config
      @session_store = session_store
      @sessions = {}
      @mutex = Mutex.new
    end

    def get_or_create(thread_id, channel_id: nil, working_dir: nil, username: nil)
      short_id = thread_id[0..7]
      @mutex.synchronize do
        session = @sessions[thread_id]
        return reuse_session(session, short_id) if session&.alive?

        # Try to resume from store before creating new
        persisted = @session_store&.load&.dig(thread_id)
        if persisted && persisted.claude_session_id
          return resume_or_create(thread_id, short_id, persisted,
                                  channel_id: channel_id, working_dir: working_dir, username: username)
        end

        create_session(thread_id, short_id, channel_id: channel_id, working_dir: working_dir, username: username)
      end
    end

    def get(thread_id)
      @mutex.synchronize { @sessions[thread_id] }
    end

    def stop_session(thread_id)
      @mutex.synchronize do
        session = @sessions.delete(thread_id)
        session&.kill
        @session_store&.remove(thread_id)
      end
    end

    def stop_all
      @mutex.synchronize do
        log(:info, "Stopping #{@sessions.size} session(s)...")
        @sessions.each_value(&:kill)
        @sessions.clear
      end
    end

    def touch(thread_id)
      @session_store&.touch(thread_id)
    end

    def resume_all
      return unless @session_store

      @session_store.load.each do |thread_id, persisted|
        resume_session(thread_id, persisted) unless persisted.is_paused
      end
    end

    def pause_all
      @mutex.synchronize do
        @sessions.each do |thread_id, session|
          @session_store&.save(thread_id, build_persisted(session, paused: :paused))
          session.kill
        end
        @sessions.clear
      end
    end

    private

    def reuse_session(session, short_id)
      log(:debug, "Reusing session for thread #{short_id}")
      session
    end

    def resume_or_create(thread_id, short_id, persisted, channel_id: nil, working_dir: nil, username: nil)
      effective_channel = channel_id || persisted.channel_id
      effective_dir = working_dir || persisted.working_dir
      log(:info, "Attempting to resume session for thread #{short_id}")
      session = ClaudeSession.new(
        session_id: persisted.claude_session_id,
        permission_config: build_permission_config(thread_id, effective_channel),
        mode: :resume,
        working_dir: effective_dir,
        username: username
      )
      session.start
      @sessions[thread_id] = session
      @session_store&.save(thread_id, build_persisted(session, channel_id: effective_channel,
                                                               working_dir: effective_dir))
      session
    rescue StandardError => error
      log(:warn, "Resume failed for thread #{short_id}: #{error.message}, creating new session")
      create_session(thread_id, short_id, channel_id: channel_id, working_dir: working_dir, username: username)
    end

    def resume_session(thread_id, persisted)
      short_id = thread_id[0..7]
      log(:info, "Resuming session for thread #{short_id}")
      session = ClaudeSession.new(
        session_id: persisted.claude_session_id,
        permission_config: build_permission_config(thread_id, persisted.channel_id),
        mode: :resume,
        working_dir: persisted.working_dir
      )
      session.start
      @mutex.synchronize { @sessions[thread_id] = session }
    rescue StandardError => error
      log(:warn, "Startup resume failed for thread #{short_id}: #{error.message}")
    end

    def create_session(thread_id, short_id, channel_id: nil, working_dir: nil, username: nil)
      log(:info, "Creating new session for thread #{short_id}")
      session = ClaudeSession.new(
        permission_config: build_permission_config(thread_id, channel_id),
        working_dir: working_dir,
        username: username
      )
      session.start
      @sessions[thread_id] = session
      @session_store&.save(thread_id, build_persisted(session, channel_id: channel_id, working_dir: working_dir))
      session
    end

    def build_permission_config(thread_id, channel_id)
      return nil unless @config && !@config.skip_permissions?

      {
        "PLATFORM_URL" => @config.mattermost_url,
        "PLATFORM_TOKEN" => @config.bot_token,
        "PLATFORM_CHANNEL_ID" => channel_id || @config.channel_id,
        "PLATFORM_THREAD_ID" => thread_id,
        "PLATFORM_BOT_ID" => @config.bot_id,
        "ALLOWED_USERS" => @config.allowed_users.join(",")
      }
    end

    def build_persisted(session, channel_id: nil, working_dir: nil, paused: :active)
      now = Time.now.iso8601
      SessionStore::PersistedSession.new(
        claude_session_id: session.session_id,
        channel_id: channel_id,
        working_dir: working_dir,
        started_at: now,
        last_activity_at: now,
        is_paused: paused == :paused,
        message_count: 0
      )
    end
  end
end
