# frozen_string_literal: true

module Earl
  class SessionManager
    # Persistence query and stats methods extracted to reduce class method count.
    module Persistence
      # Returns [session_id, working_dir] for a thread, checking active
      # sessions first, then falling back to the persisted session store.
      SessionInfo = Data.define(:session_id, :working_dir)

      def session_info_for(thread_id)
        @mutex.synchronize do
          session = @sessions[thread_id]
          return SessionInfo.new(session_id: session.session_id, working_dir: session.working_dir) if session

          persisted = persisted_session_for(thread_id)
          return nil unless persisted&.claude_session_id

          SessionInfo.new(session_id: persisted.claude_session_id, working_dir: persisted.working_dir)
        end
      end

      def claude_session_id_for(thread_id)
        session_info_for(thread_id)&.session_id
      end

      # Returns the persisted session data for a thread from the session store.
      def persisted_session_for(thread_id)
        @session_store&.load&.dig(thread_id)
      end

      def save_stats(thread_id)
        @mutex.synchronize do
          session = @sessions[thread_id]
          return unless session && @session_store

          persisted = @session_store.load[thread_id]
          return unless persisted

          apply_stats_to_persisted(persisted, session)
          @session_store.save(thread_id, persisted)
        end
      end

      private

      def mark_all_stale_as_paused
        @session_store.load.each do |thread_id, persisted|
          next if persisted.is_paused

          log(:info, "Marking stale session #{thread_id[0..7]} as paused (no live process)")
          @session_store.mark_paused(thread_id)
        end
      end

      def apply_stats_to_persisted(persisted, session)
        stats = session.stats
        persisted.total_cost = stats.total_cost
        persisted.total_input_tokens = stats.total_input_tokens
        persisted.total_output_tokens = stats.total_output_tokens
      end
    end
  end
end
