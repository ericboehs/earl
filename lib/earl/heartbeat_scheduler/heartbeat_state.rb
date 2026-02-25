# frozen_string_literal: true

module Earl
  class HeartbeatScheduler
    # Per-heartbeat runtime state.
    HeartbeatState = Struct.new(
      :definition, :next_run_at, :running, :run_thread, :last_run_at,
      :last_completed_at, :last_error, :run_count, :session_id,
      keyword_init: true
    ) do
      def to_status
        {
          name: definition.name, description: definition.description,
          next_run_at: next_run_at, last_run_at: last_run_at,
          last_completed_at: last_completed_at, last_error: last_error,
          run_count: run_count, running: running
        }
      end

      def update_definition_if_idle(new_definition)
        return if running

        self.definition = new_definition
      end

      def dispatch(now, &block)
        self.running = true
        self.last_run_at = now
        self.run_thread = Thread.new(&block)
      end

      def mark_completed(next_run)
        self.running = false
        self.last_completed_at = Time.now
        self.run_count += 1
        self.run_thread = nil
        self.next_run_at = next_run
      end
    end
  end
end
