# frozen_string_literal: true

module Earl
  # Thread-safe registry of active Claude sessions, keyed by Mattermost
  # thread ID, with lazy creation and coordinated shutdown.
  class SessionManager
    include Logging

    def initialize
      @sessions = {}
      @mutex = Mutex.new
    end

    # :reek:TooManyStatements
    def get_or_create(thread_id)
      short_id = thread_id[0..7]
      @mutex.synchronize do
        session = @sessions[thread_id]

        if session&.alive?
          log(:debug, "Reusing session for thread #{short_id}")
          return session
        end

        log(:info, "Creating new session for thread #{short_id}")
        session = ClaudeSession.new
        session.start
        @sessions[thread_id] = session
        session
      end
    end

    def stop_all
      @mutex.synchronize do
        log(:info, "Stopping #{@sessions.size} session(s)...")
        @sessions.each_value(&:kill)
        @sessions.clear
      end
    end
  end
end
