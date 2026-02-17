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

    def initialize(config:, session_manager:, mattermost:)
      @config = config
      @session_manager = session_manager
      @mattermost = mattermost
      @heartbeat_config = HeartbeatConfig.new
      @heartbeat_config_path = @heartbeat_config.path
      @states = {}
      @mutex = Mutex.new
      @scheduler_thread = nil
      @config_mtime = nil
      @stop_requested = false
    end

    def start
      @stop_requested = false
      definitions = @heartbeat_config.definitions
      initialize_states(definitions) unless definitions.empty?
      @config_mtime = config_file_mtime

      count = definitions.size
      log(:info, "Heartbeat scheduler starting with #{count} heartbeat(s)")

      @scheduler_thread = Thread.new { scheduler_loop }
    end

    def stop
      @stop_requested = true
      @scheduler_thread&.join(5)
      @scheduler_thread&.kill if @scheduler_thread&.alive?
      @scheduler_thread = nil

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
        break if @stop_requested

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
      !state.running && state.next_run_at && now >= state.next_run_at
    end

    def dispatch_heartbeat(state, now)
      state.running = true
      state.last_run_at = now
      state.run_thread = Thread.new { execute_heartbeat(state) }
    end

    def execute_heartbeat(state)
      definition = state.definition
      log(:info, "Heartbeat '#{definition.name}' starting")

      header_post = create_header_post(definition)
      return unless header_post

      thread_id = header_post["id"]
      unless thread_id
        log(:error, "Heartbeat '#{definition.name}': failed to get post ID from Mattermost")
        return
      end

      session = create_heartbeat_session(definition, state)
      run_session(session, definition, thread_id, state)
    rescue StandardError => error
      log(:error, "Heartbeat '#{definition.name}' error: #{error.message}")
      log(:error, error.backtrace&.first(5)&.join("\n"))
      @mutex.synchronize { state.last_error = error.message }
    ensure
      finalize_heartbeat(state)
    end

    def create_header_post(definition)
      @mattermost.create_post(
        channel_id: definition.channel_id,
        message: "🫀 **#{definition.description}**"
      )
    end

    def create_heartbeat_session(definition, state)
      session_opts = {
        permission_config: permission_config(definition),
        working_dir: definition.working_dir
      }

      if definition.persistent && state.session_id
        session_opts[:session_id] = state.session_id
        session_opts[:mode] = :resume
      end

      session = ClaudeSession.new(**session_opts)
      @mutex.synchronize { state.session_id = session.session_id } if definition.persistent
      session
    end

    def permission_config(definition)
      return nil if definition.permission_mode == :auto

      # Heartbeats use per-definition permission_mode, bypassing the global
      # skip_permissions setting. Build the env hash directly.
      {
        "PLATFORM_URL" => @config.mattermost_url,
        "PLATFORM_TOKEN" => @config.bot_token,
        "PLATFORM_CHANNEL_ID" => definition.channel_id,
        "PLATFORM_THREAD_ID" => "",
        "PLATFORM_BOT_ID" => @config.bot_id,
        "ALLOWED_USERS" => @config.allowed_users.join(",")
      }
    end

    def run_session(session, definition, thread_id, state)
      completed = false
      response = StreamingResponse.new(
        thread_id: thread_id, mattermost: @mattermost, channel_id: definition.channel_id
      )
      response.start_typing

      session.on_text { |text| response.on_text(text) }
      session.on_complete do |_|
        response.on_complete
        completed = true
      end
      session.on_tool_use { |tool_use| response.on_tool_use(tool_use) }

      session.start
      session.send_message(definition.prompt)

      wait_for_completion(session, definition, completed) { completed }
      log(:info, "Heartbeat '#{definition.name}' completed (run ##{state.run_count + 1})")
    end

    def wait_for_completion(session, definition, _completed)
      deadline = Time.now + definition.timeout
      until yield
        if Time.now >= deadline
          log(:warn, "Heartbeat '#{definition.name}' timed out after #{definition.timeout}s")
          session.kill
          return
        end
        sleep 1
      end
    end

    def finalize_heartbeat(state)
      @mutex.synchronize do
        state.running = false
        state.last_completed_at = Time.now
        state.run_count += 1
        state.run_thread = nil

        if state.definition.once
          state.next_run_at = nil
          disable_heartbeat(state.definition.name)
        else
          state.next_run_at = compute_next_run(state.definition, Time.now)
        end
      end
    end

    def compute_next_run(definition, from)
      if definition.run_at
        target = Time.at(definition.run_at)
        target > from ? target : from
      elsif definition.cron
        CronParser.new(definition.cron).next_occurrence(from: from)
      elsif definition.interval
        from + definition.interval
      end
    end

    def disable_heartbeat(name)
      path = @heartbeat_config_path
      return unless File.exist?(path)

      # Use file lock to coordinate with HeartbeatHandler YAML writes
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

    # --- Auto-reload ---

    def check_for_reload
      mtime = config_file_mtime
      return if mtime == @config_mtime

      @config_mtime = mtime
      reload_definitions
    end

    def reload_definitions
      new_defs = @heartbeat_config.definitions
      now = Time.now
      new_names = new_defs.map(&:name)

      @mutex.synchronize do
        # Add new heartbeats
        new_defs.each do |definition|
          unless @states.key?(definition.name)
            @states[definition.name] = HeartbeatState.new(
              definition: definition,
              next_run_at: compute_next_run(definition, now),
              running: false,
              run_count: 0
            )
            log(:info, "Heartbeat reload: added '#{definition.name}'")
          end
        end

        # Remove deleted heartbeats (skip running ones)
        @states.each_key do |name|
          next if new_names.include?(name)
          next if @states[name].running

          @states.delete(name)
          log(:info, "Heartbeat reload: removed '#{name}'")
        end

        # Update definitions for existing non-running heartbeats
        new_defs.each do |definition|
          state = @states[definition.name]
          next unless state
          next if state.running

          state.definition = definition
        end
      end

      log(:info, "Heartbeat config reloaded: #{new_defs.size} definition(s)")
    end

    def config_file_mtime
      File.mtime(@heartbeat_config_path)
    rescue Errno::ENOENT
      nil
    end

    # Builds a status hash for a single heartbeat for the !heartbeats command.
    module StatusFormatting
      private

      def build_status(state)
        {
          name: state.definition.name,
          description: state.definition.description,
          next_run_at: state.next_run_at,
          last_run_at: state.last_run_at,
          last_completed_at: state.last_completed_at,
          last_error: state.last_error,
          run_count: state.run_count,
          running: state.running
        }
      end
    end

    include StatusFormatting
  end
end
