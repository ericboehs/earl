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
    )

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
      state.running = true
      state.last_run_at = now
      state.run_thread = Thread.new { execute_heartbeat(state) }
    end

    # Heartbeat execution: creates sessions, streams responses, handles completion.
    module Execution
      private

      def execute_heartbeat(state)
        definition = state.definition
        name = definition.name
        log(:info, "Heartbeat '#{name}' starting")

        header_post = create_header_post(definition)
        return unless header_post

        thread_id = header_post["id"]
        unless thread_id
          log(:error, "Heartbeat '#{name}': failed to get post ID from Mattermost")
          return
        end

        session = create_heartbeat_session(definition, state)
        run_session(session, thread_id, state)
      rescue StandardError => error
        msg = error.message
        log(:error, "Heartbeat '#{name}' error: #{msg}")
        log(:error, error.backtrace&.first(5)&.join("\n"))
        @mutex.synchronize { state.last_error = msg }
      ensure
        finalize_heartbeat(state)
      end

      def create_header_post(definition)
        @deps.mattermost.create_post(
          channel_id: definition.channel_id,
          message: "\u{1FAC0} **#{definition.description}**"
        )
      end

      def create_heartbeat_session(definition, state)
        persistent = definition.persistent
        session_opts = {
          permission_config: permission_config(definition),
          working_dir: definition.working_dir
        }

        saved_session_id = state.session_id
        if persistent && saved_session_id
          session_opts[:session_id] = saved_session_id
          session_opts[:mode] = :resume
        end

        session = ClaudeSession.new(**session_opts)
        @mutex.synchronize { state.session_id = session.session_id } if persistent
        session
      end

      def permission_config(definition)
        return nil if definition.permission_mode == :auto

        config = @deps.config
        {
          "PLATFORM_URL" => config.mattermost_url,
          "PLATFORM_TOKEN" => config.bot_token,
          "PLATFORM_CHANNEL_ID" => definition.channel_id,
          "PLATFORM_THREAD_ID" => "",
          "PLATFORM_BOT_ID" => config.bot_id,
          "ALLOWED_USERS" => config.allowed_users.join(",")
        }
      end

      def run_session(session, thread_id, state)
        definition = state.definition
        completed = false
        response = StreamingResponse.new(
          thread_id: thread_id, mattermost: @deps.mattermost, channel_id: definition.channel_id
        )
        response.start_typing

        setup_heartbeat_callbacks(session, response) { completed = true }
        session.start
        session.send_message(definition.prompt)

        wait_for_completion(session, definition, completed) { completed }
        log(:info, "Heartbeat '#{definition.name}' completed (run ##{state.run_count + 1})")
      end

      def setup_heartbeat_callbacks(session, response)
        session.on_text { |text| response.on_text(text) }
        session.on_complete { |_| response.on_complete; yield }
        session.on_tool_use { |tool_use| response.on_tool_use(tool_use) }
      end

      def wait_for_completion(session, definition, _completed)
        timeout = definition.timeout
        deadline = Time.now + timeout
        until yield
          if Time.now >= deadline
            log(:warn, "Heartbeat '#{definition.name}' timed out after #{timeout}s")
            session.kill
            return
          end
          sleep 1
        end
      end

      def finalize_heartbeat(state)
        definition = state.definition
        now = Time.now
        @mutex.synchronize do
          state.running = false
          state.last_completed_at = now
          state.run_count += 1
          state.run_thread = nil

          if definition.once
            state.next_run_at = nil
            disable_heartbeat(definition.name)
          else
            state.next_run_at = compute_next_run(definition, now)
          end
        end
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

        File.open(path, "r+") do |lockfile|
          lockfile.flock(File::LOCK_EX)

          data = YAML.safe_load_file(path)
          return unless data.is_a?(Hash) && data.dig("heartbeats", name).is_a?(Hash)

          data["heartbeats"][name]["enabled"] = false
          tmp_path = "#{path}.tmp.#{Process.pid}"
          File.write(tmp_path, YAML.dump(data))
          File.rename(tmp_path, path)
          log(:info, "One-off heartbeat '#{name}' disabled in YAML")
        end
      rescue StandardError => error
        log(:warn, "Failed to disable heartbeat '#{name}': #{error.message}")
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
          state = @states[definition.name]
          next unless state
          next if state.running

          state.definition = definition
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
        definition = state.definition
        {
          name: definition.name,
          description: definition.description,
          next_run_at: state.next_run_at,
          last_run_at: state.last_run_at,
          last_completed_at: state.last_completed_at,
          last_error: state.last_error,
          run_count: state.run_count,
          running: state.running
        }
      end
    end

    include Execution
    include ConfigReloading
    include StatusFormatting
  end
end
