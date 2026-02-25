# frozen_string_literal: true

require_relative "heartbeat_scheduler/heartbeat_state"
require_relative "heartbeat_scheduler/execution"
require_relative "heartbeat_scheduler/lifecycle"
require_relative "heartbeat_scheduler/config_reloading"

module Earl
  # Runs heartbeat tasks on cron/interval/one-shot schedules. Spawns Claude sessions
  # and posts results to Mattermost channels without waiting for user messages.
  # Auto-reloads config when the YAML file changes. One-off tasks (once: true)
  # are disabled in YAML after execution.
  class HeartbeatScheduler
    include Logging
    include Execution
    include Lifecycle
    include ConfigReloading

    CHECK_INTERVAL = 30 # seconds between scheduler checks

    # Groups injected service dependencies to keep ivar count low.
    Deps = Struct.new(:config, :mattermost, :heartbeat_config, keyword_init: true)

    # Groups scheduler control state.
    Control = Struct.new(:scheduler_thread, :stop_requested, :config_mtime, :heartbeat_config_path, keyword_init: true)

    def initialize(config:, mattermost:)
      heartbeat_config = HeartbeatConfig.new
      @deps = Deps.new(config: config, mattermost: mattermost, heartbeat_config: heartbeat_config)
      @control = Control.new(
        scheduler_thread: nil, stop_requested: false,
        config_mtime: nil, heartbeat_config_path: heartbeat_config.path
      )
      @states = {}
      @mutex = Mutex.new
    end

    def start
      @control.stop_requested = false
      definitions = @deps.heartbeat_config.definitions
      initialize_states(definitions) unless definitions.empty?
      @control.config_mtime = config_file_mtime

      count = definitions.size
      log(:info, "Heartbeat scheduler starting with #{count} heartbeat(s)")

      @control.scheduler_thread = Thread.new { scheduler_loop }
    end

    def stop
      @control.stop_requested = true
      join_and_kill_thread(@control.scheduler_thread)
      @control.scheduler_thread = nil
      stop_heartbeat_threads
    end

    def status
      @mutex.synchronize do
        @states.values.map(&:to_status)
      end
    end

    private

    def join_and_kill_thread(thread)
      return unless thread

      thread.join(5)
      thread.kill if thread.alive?
    end

    def stop_heartbeat_threads
      @mutex.synchronize do
        @states.each_value do |state|
          thread = state.run_thread
          thread&.join(3)
          thread&.kill if thread&.alive?
        end
      end
    end

    def initialize_states(definitions)
      now = Time.now
      @mutex.synchronize do
        definitions.each do |definition|
          @states[definition.name] = build_initial_state(definition, now)
        end
      end
    end

    def build_initial_state(definition, now)
      HeartbeatState.new(
        definition: definition,
        next_run_at: compute_next_run(definition, now),
        running: false,
        run_count: 0
      )
    end

    def scheduler_loop
      loop do
        break if @control.stop_requested

        check_for_reload
        check_and_dispatch
        sleep CHECK_INTERVAL
      rescue StandardError => error
        log(:error, "Heartbeat scheduler error: #{error.message}")
        log(:error, error.backtrace&.first(5)&.join("\n"))
      end
    end

    def check_and_dispatch
      now = Time.now
      @mutex.synchronize do
        @states.each_value do |state|
          dispatch_heartbeat(state, now) if should_run?(state, now)
        end
      end
    end

    def should_run?(state, now)
      next_run = state.next_run_at
      !state.running && next_run && now >= next_run
    end

    def dispatch_heartbeat(state, now)
      state.dispatch(now) { execute_heartbeat(state) }
    end
  end
end
