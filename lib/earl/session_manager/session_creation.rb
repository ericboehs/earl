# frozen_string_literal: true

module Earl
  class SessionManager
    # Session creation, resumption, and spawning logic.
    module SessionCreation
      private

      def reuse_session(session, short_id)
        log(:debug, "Reusing session for thread #{short_id}")
        session
      end

      def resume_or_create(ctx, persisted)
        build_resume_session(ctx, persisted)
      rescue StandardError => error
        log(:warn, "Resume failed for thread #{ctx.short_id}: #{error.message}, creating new session")
        create_session(ctx)
      end

      def build_resume_session(ctx, persisted)
        thread_id, short_id, session_config = ctx.deconstruct
        sc_channel, sc_dir, sc_user = session_config.deconstruct
        p_sid, p_chan, p_dir = persisted.to_h.values_at(:claude_session_id, :channel_id, :working_dir)
        log(:info, "Attempting to resume session for thread #{short_id}")
        spawn_and_register(SpawnParams.new(
                             session_id: p_sid, thread_id: thread_id,
                             channel_id: sc_channel || p_chan,
                             working_dir: sc_dir || p_dir, username: sc_user
                           ))
      end

      def resume_session(thread_id, persisted)
        short_id = thread_id[0..7]
        log(:info, "Resuming session for thread #{short_id}")
        params = SpawnParams.new(
          session_id: persisted.claude_session_id, thread_id: thread_id,
          channel_id: persisted.channel_id, working_dir: persisted.working_dir, username: nil
        )
        session = spawn_claude_session(params)
        @mutex.synchronize { @sessions[thread_id] = session }
      rescue StandardError => error
        log(:warn, "Startup resume failed for thread #{short_id}: #{error.message}")
      end

      def create_session(ctx)
        thread_id, short_id, session_config = ctx.deconstruct
        channel_id, working_dir, username = session_config.deconstruct
        log(:info, "Creating new session for thread #{short_id}")
        params = SpawnParams.new(
          session_id: nil, thread_id: thread_id,
          channel_id: channel_id, working_dir: working_dir, username: username
        )
        spawn_and_register(params)
      end

      def spawn_and_register(params)
        _, thread_id, channel_id, working_dir, = params.deconstruct
        session = spawn_claude_session(params)
        persist_ctx = PersistenceContext.new(channel_id: channel_id, working_dir: working_dir, paused: false)
        register_session(thread_id, session, persist_ctx)
        session
      end

      def spawn_claude_session(params)
        sid, thread_id, channel_id, working_dir, username = params.deconstruct
        session = ClaudeSession.new(
          **(sid ? { session_id: sid } : {}),
          permission_config: build_permission_config(thread_id, channel_id),
          mode: sid ? :resume : :new,
          working_dir: working_dir, username: username
        )
        session.start
        session
      end

      def register_session(thread_id, session, persist_ctx)
        @sessions[thread_id] = session
        @session_store&.save(thread_id, build_persisted(session, persist_ctx))
      end

      def build_permission_config(thread_id, channel_id)
        return nil unless @config

        resolved = [channel_id, @config.channel_id].compact.first
        mcp_config = @config.build_mcp_config(channel_id: resolved, thread_id: thread_id)
        merge_mcp_config_env(mcp_config)
      end

      def build_persisted(session, persist_ctx)
        now = Time.now.iso8601
        p_channel_id, p_working_dir, paused = persist_ctx.deconstruct
        SessionStore::PersistedSession.new(
          claude_session_id: session.session_id,
          channel_id: p_channel_id, working_dir: p_working_dir,
          started_at: now, last_activity_at: now,
          is_paused: paused, message_count: 0,
          **stats_hash(session)
        )
      end

      def stats_hash(session)
        stats = session.stats
        { total_cost: stats.total_cost, total_input_tokens: stats.total_input_tokens,
          total_output_tokens: stats.total_output_tokens }
      end
    end
  end
end
