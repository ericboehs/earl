# frozen_string_literal: true

module Earl
  # Runs heartbeat tasks on cron/interval/one-shot schedules. Spawns Claude sessions
  # and posts results to Mattermost channels without waiting for user messages.
  # Auto-reloads config when the YAML file changes. One-off tasks (once: true)
  # are disabled in YAML after execution.
  class HeartbeatScheduler
    include Logging

    CHECK_INTERVAL = 30 # seconds between scheduler checks

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
      thread = @control.scheduler_thread
      thread&.join(5)
      thread&.kill if thread&.alive?
      @control.scheduler_thread = nil

      @mutex.synchronize do
        @states.each_value do |state|
          thread = state.run_thread
          thread&.join(3)
          thread&.kill if thread&.alive?
        end
      end
    end

    def status
      @mutex.synchronize do
        @states.values.map { |state| build_status(state) }
      end
    end

    private

    def initialize_states(definitions)
      now = Time.now
      @mutex.synchronize do
        definitions.each do |definition|
          @states[definition.name] = HeartbeatState.new(
            definition: definition,
            next_run_at: compute_next_run(definition, now),
            running: false,
            run_count: 0
          )
        end
      end
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

    # Heartbeat execution: creates sessions, streams responses, handles completion.
    module Execution
      private

      def execute_heartbeat(state)
        definition = state.definition
        name = definition.name
        log(:info, "Heartbeat '#{name}' starting")
        thread_id = post_heartbeat_header(definition.channel_id, definition.description)
        return unless thread_id

        run_heartbeat_session(definition, state, thread_id)
      rescue StandardError => error
        log_heartbeat_error(name, error)
        @mutex.synchronize { state.last_error = error.message }
      ensure
        finalize_heartbeat(state)
      end

      def log_heartbeat_error(name, error)
        log(:error, "Heartbeat '#{name}' error: #{error.message}")
        log(:error, error.backtrace&.first(5)&.join("\n"))
      end

      def post_heartbeat_header(channel_id, description)
        post = @deps.mattermost.create_post(channel_id: channel_id, message: "\u{1FAC0} **#{description}**")
        post&.dig("id")
      end

      def run_heartbeat_session(definition, state, thread_id)
        session = build_heartbeat_session(definition, state)
        completed = false
        response = build_heartbeat_response(thread_id, definition.channel_id)
        setup_heartbeat_callbacks(session, response) { completed = true }
        session.start
        session.send_message(definition.prompt)
        await_heartbeat_completion(session, definition.timeout) { completed }
        log(:info, "Heartbeat '#{definition.name}' completed (run ##{state.run_count + 1})")
      end

      def build_heartbeat_response(thread_id, channel_id)
        response = StreamingResponse.new(thread_id: thread_id, mattermost: @deps.mattermost, channel_id: channel_id)
        response.start_typing
        response
      end

      def build_heartbeat_session(definition, state)
        persistent = definition.persistent
        session_opts = heartbeat_session_opts(definition)
        apply_resume_opts(session_opts, state) if persistent
        session = ClaudeSession.new(**session_opts)
        @mutex.synchronize { state.session_id = session.session_id } if persistent
        session
      end

      def heartbeat_session_opts(definition)
        auto, channel_id, working_dir = definition.base_session_opts.values_at(:auto_permission, :channel_id, :working_dir)
        { working_dir: working_dir, permission_config: auto ? nil : heartbeat_permission_env(channel_id) }
      end

      def apply_resume_opts(opts, state)
        saved_session_id = state.session_id
        return unless saved_session_id

        opts[:session_id] = saved_session_id
        opts[:mode] = :resume
      end

      def heartbeat_permission_env(channel_id)
        @deps.config.permission_env(channel_id: channel_id)
      end

      def setup_heartbeat_callbacks(session, response)
        session.on_text { |text| response.on_text(text) }
        session.on_complete { |_| response.on_complete; yield }
        session.on_tool_use { |tool_use| response.on_tool_use(tool_use) }
      end

      def await_heartbeat_completion(session, timeout)
        start_time = monotonic_now
        until yield
          if monotonic_now - start_time >= timeout
            log(:warn, "Heartbeat timed out after #{timeout}s")
            session.kill
            return
          end
          sleep 1
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def finalize_heartbeat(state)
        definition = state.definition
        is_once = definition.once
        next_run = is_once ? nil : compute_next_run(definition, Time.now)
        @mutex.synchronize { state.mark_completed(next_run) }
        disable_heartbeat(definition.name) if is_once
      end

      def compute_next_run(definition, from)
        run_at = definition.run_at
        cron = definition.cron
        interval = definition.interval

        if run_at
          target = Time.at(run_at)
          target > from ? target : from
        elsif cron
          CronParser.new(cron).next_occurrence(from: from)
        elsif interval
          from + interval
        end
      end

      def disable_heartbeat(name)
        path = @control.heartbeat_config_path
        return unless File.exist?(path)

        update_yaml_entry(path, name)
      rescue StandardError => error
        log(:warn, "Failed to disable heartbeat '#{name}': #{error.message}")
      end

      def update_yaml_entry(path, name)
        File.open(path, "r+") do |lockfile|
          lockfile.flock(File::LOCK_EX)
          yaml_data = YAML.safe_load_file(path)
          return unless disable_entry(yaml_data, name)

          write_yaml_atomically(path, yaml_data)
          log(:info, "One-off heartbeat '#{name}' disabled in YAML")
        end
      end

      def disable_entry(yaml_data, name)
        return false unless yaml_data.is_a?(Hash)

        entry = yaml_data.dig("heartbeats", name)
        return false unless entry.is_a?(Hash)

        entry["enabled"] = false
        true
      end

      def write_yaml_atomically(path, data)
        tmp_path = "#{path}.tmp.#{Process.pid}"
        File.write(tmp_path, YAML.dump(data))
        File.rename(tmp_path, path)
      end
    end

    # Auto-reload: detects config file changes and updates heartbeat definitions.
    module ConfigReloading
      private

      def check_for_reload
        mtime = config_file_mtime
        return if mtime == @control.config_mtime

        @control.config_mtime = mtime
        reload_definitions
      end

      def reload_definitions
        new_defs = @deps.heartbeat_config.definitions
        now = Time.now
        new_names = new_defs.map(&:name)

        @mutex.synchronize do
          add_new_definitions(new_defs, now)
          remove_stale_definitions(new_names)
          update_existing_definitions(new_defs)
        end

        log(:info, "Heartbeat config reloaded: #{new_defs.size} definition(s)")
      end

      def add_new_definitions(new_defs, now)
        new_defs.each do |definition|
          name = definition.name
          next if @states.key?(name)

          @states[name] = HeartbeatState.new(
            definition: definition,
            next_run_at: compute_next_run(definition, now),
            running: false,
            run_count: 0
          )
          log(:info, "Heartbeat reload: added '#{name}'")
        end
      end

      def remove_stale_definitions(new_names)
        @states.each_key do |name|
          next if new_names.include?(name)
          next if @states[name].running

          @states.delete(name)
          log(:info, "Heartbeat reload: removed '#{name}'")
        end
      end

      def update_existing_definitions(new_defs)
        new_defs.each do |definition|
          @states[definition.name]&.update_definition_if_idle(definition)
        end
      end

      def config_file_mtime
        File.mtime(@control.heartbeat_config_path)
      rescue Errno::ENOENT
        nil
      end
    end

    # Builds a status hash for a single heartbeat for the !heartbeats command.
    module StatusFormatting
      private

      def build_status(state)
        state.to_status
      end
    end

    include Execution
    include ConfigReloading
    include StatusFormatting
  end
end
