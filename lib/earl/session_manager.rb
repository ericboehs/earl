# frozen_string_literal: true

require_relative "session_manager/persistence"
require_relative "session_manager/session_creation"

module Earl
  # Thread-safe registry of active Claude sessions, keyed by Mattermost
  # thread ID, with lazy creation, coordinated shutdown, and optional persistence.
  class SessionManager
    include Logging
    include PermissionConfig

    # Bundles session creation parameters that travel together.
    SessionConfig = Data.define(:channel_id, :working_dir, :username)

    # Bundles thread identity with session config to eliminate data clump.
    ThreadContext = Data.define(:thread_id, :short_id, :session_config)

    # Bundles persistence parameters to reduce parameter list length.
    PersistenceContext = Data.define(:channel_id, :working_dir, :paused)

    # Bundles parameters for spawning a new Claude session.
    SpawnParams = Data.define(:session_id, :thread_id, :channel_id, :working_dir, :username)

    def initialize(config: nil, session_store: nil)
      @config = config
      @session_store = session_store
      @sessions = {}
      @mutex = Mutex.new
    end

    def get_or_create(thread_id, session_config)
      ctx = ThreadContext.new(thread_id: thread_id, short_id: thread_id[0..7],
                              session_config: session_config)
      @mutex.synchronize do
        session = @sessions[thread_id]
        return reuse_session(session, ctx.short_id) if session&.alive?

        persisted = @session_store&.load&.dig(thread_id)
        return resume_or_create(ctx, persisted) if persisted&.claude_session_id

        create_session(ctx)
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
          persist_ctx = PersistenceContext.new(channel_id: nil, working_dir: nil, paused: true)
          @session_store&.save(thread_id, build_persisted(session, persist_ctx))
          session.kill
        end
        @sessions.clear
      end
    end

    include Persistence
    include SessionCreation
  end
end
