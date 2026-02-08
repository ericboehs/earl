# frozen_string_literal: true

module Earl
  class SessionManager
    def initialize
      @sessions = {}
      @mutex = Mutex.new
    end

    def get_or_create(thread_id)
      @mutex.synchronize do
        session = @sessions[thread_id]

        if session&.alive?
          Earl.logger.debug "Reusing session for thread #{thread_id[0..7]}"
          return session
        end

        Earl.logger.info "Creating new session for thread #{thread_id[0..7]}"
        session = ClaudeSession.new
        session.start
        @sessions[thread_id] = session
        session
      end
    end

    def stop_all
      @mutex.synchronize do
        Earl.logger.info "Stopping #{@sessions.size} session(s)..."
        @sessions.each_value(&:kill)
        @sessions.clear
      end
    end
  end
end
