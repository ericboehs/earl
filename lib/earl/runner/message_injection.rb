# frozen_string_literal: true

module Earl
  class Runner
    # Mid-response injection: writes directly to Claude stdin when busy but alive.
    module MessageInjection
      private

      def inject_or_enqueue(msg)
        thread_id = msg.thread_id
        queue = @app_state.message_queue
        session = @services.session_manager.get(thread_id)
        if session&.alive?
          queue.inject(thread_id)
          session.inject_message(msg.text)
          log(:info, "Injected message into active session for thread #{thread_id[0..7]}")
        else
          queue.enqueue(thread_id, msg)
        end
      end
    end
  end
end
