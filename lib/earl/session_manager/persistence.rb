# frozen_string_literal: true

module Earl
  class SessionManager
    # Persistence query and stats methods extracted to reduce class method count.
    module Persistence
      # Returns the Claude session ID for a thread, checking active sessions
      # first, then falling back to the persisted session store.
      def claude_session_id_for(thread_id)
        @mutex.synchronize do
          session = @sessions[thread_id]
          return session.session_id if session

          persisted_session_for(thread_id)&.claude_session_id
        end
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

      def apply_stats_to_persisted(persisted, session)
        stats = session.stats
        persisted.total_cost = stats.total_cost
        persisted.total_input_tokens = stats.total_input_tokens
        persisted.total_output_tokens = stats.total_output_tokens
      end
    end
  end
end
