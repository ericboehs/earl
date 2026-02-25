# frozen_string_literal: true

module Earl
  class Runner
    # Idle session management.
    module IdleManagement
      private

      def start_idle_checker
        @app_state.idle_checker_thread = Thread.new do
          loop do
            sleep IDLE_CHECK_INTERVAL
            check_idle_sessions
          rescue StandardError => error
            log(:error, "Idle checker error: #{error.message}")
          end
        end
      end

      def check_idle_sessions
        @services.session_store.load.each do |thread_id, persisted|
          stop_if_idle(thread_id, persisted)
        end
      end

      def stop_if_idle(thread_id, persisted)
        return if persisted.is_paused

        idle_seconds = seconds_since_activity(persisted.last_activity_at)
        return unless idle_seconds
        return unless idle_seconds > IDLE_TIMEOUT

        log(:info, "Stopping idle session for thread #{thread_id[0..7]} (idle #{(idle_seconds / 60).round}min)")
        @services.session_manager.stop_session(thread_id)
      end

      def seconds_since_activity(last_activity_at)
        return nil unless last_activity_at

        Time.now - Time.parse(last_activity_at)
      end
    end
  end
end
