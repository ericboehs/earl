# frozen_string_literal: true

require "test_helper"

module Earl
  class HeartbeatSchedulerTest < Minitest::Test
    setup do
      Earl.logger = Logger.new(File::NULL)

      @original_env = ENV.to_h.slice(
        "MATTERMOST_URL", "MATTERMOST_BOT_TOKEN", "MATTERMOST_BOT_ID",
        "EARL_CHANNEL_ID", "EARL_ALLOWED_USERS", "EARL_SKIP_PERMISSIONS"
      )

      ENV["MATTERMOST_URL"] = "https://mattermost.example.com"
      ENV["MATTERMOST_BOT_TOKEN"] = "test-token"
      ENV["MATTERMOST_BOT_ID"] = "bot-123"
      ENV["EARL_CHANNEL_ID"] = "channel-456"
      ENV["EARL_ALLOWED_USERS"] = ""
      ENV["EARL_SKIP_PERMISSIONS"] = "true"

      # Speed up scheduler_loop sleep from 30s to 0.01s for tests
      @original_check_interval = Earl::HeartbeatScheduler::CHECK_INTERVAL
      Earl::HeartbeatScheduler.send(:remove_const, :CHECK_INTERVAL)
      Earl::HeartbeatScheduler.const_set(:CHECK_INTERVAL, 0.01)
    end

    teardown do
      Earl.logger = nil

      # Restore CHECK_INTERVAL
      Earl::HeartbeatScheduler.send(:remove_const, :CHECK_INTERVAL)
      Earl::HeartbeatScheduler.const_set(:CHECK_INTERVAL, @original_check_interval)

      %w[MATTERMOST_URL MATTERMOST_BOT_TOKEN MATTERMOST_BOT_ID EARL_CHANNEL_ID EARL_ALLOWED_USERS
         EARL_SKIP_PERMISSIONS].each do |key|
        if @original_env.key?(key)
          ENV[key] = @original_env[key]
        else
          ENV.delete(key)
        end
      end
    end

    test "should_run? returns true when not running and past next_run_at" do
      scheduler = build_scheduler
      state = build_state(running: false, next_run_at: Time.now - 60)
      assert scheduler.send(:should_run?, state, Time.now)
    end

    test "should_run? returns false when already running" do
      scheduler = build_scheduler
      state = build_state(running: true, next_run_at: Time.now - 60)
      assert_not scheduler.send(:should_run?, state, Time.now)
    end

    test "should_run? returns false when next_run_at is in future" do
      scheduler = build_scheduler
      state = build_state(running: false, next_run_at: Time.now + 3600)
      assert_not scheduler.send(:should_run?, state, Time.now)
    end

    test "should_run? returns false when next_run_at is nil" do
      scheduler = build_scheduler
      state = build_state(running: false, next_run_at: nil)
      assert_not scheduler.send(:should_run?, state, Time.now)
    end

    test "status returns empty array when no heartbeats" do
      scheduler = build_scheduler
      assert_equal [], scheduler.status
    end

    test "status returns heartbeat status hashes" do
      scheduler = build_scheduler
      definition = build_definition(name: "test_beat")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, next_run_at: Time.now + 3600,
        running: false, run_count: 3, last_run_at: Time.now - 3600
      )
      scheduler.instance_variable_get(:@states)["test_beat"] = state

      statuses = scheduler.status
      assert_equal 1, statuses.size
      assert_equal "test_beat", statuses.first[:name]
      assert_equal 3, statuses.first[:run_count]
      assert_equal false, statuses.first[:running]
    end

    test "create_header_post posts to mattermost" do
      posted = []
      mock_mm = build_mock_mattermost(posted: posted)
      scheduler = build_scheduler(mattermost: mock_mm)

      definition = build_definition(description: "Morning briefing")
      result = scheduler.send(:post_heartbeat_header, definition.channel_id, definition.description)

      assert_equal 1, posted.size
      assert_includes posted.first[:message], "Morning briefing"
      assert_includes posted.first[:message], "🫀"
      assert_equal("header-post-1", result)
    end

    test "compute_next_run uses cron parser for cron definitions" do
      scheduler = build_scheduler
      definition = build_definition(cron: "0 9 * * *")
      now = Time.new(2026, 2, 14, 8, 0, 0)

      next_run = scheduler.send(:compute_next_run, definition, now)
      assert_equal Time.new(2026, 2, 14, 9, 0, 0), next_run
    end

    test "compute_next_run uses interval for interval definitions" do
      scheduler = build_scheduler
      definition = build_definition(interval: 3600)
      now = Time.new(2026, 2, 14, 8, 0, 0)

      next_run = scheduler.send(:compute_next_run, definition, now)
      assert_equal Time.new(2026, 2, 14, 9, 0, 0), next_run
    end

    test "finalize_heartbeat resets running state and increments run_count" do
      scheduler = build_scheduler
      definition = build_definition(interval: 60)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 2,
        run_thread: Thread.new { sleep 0 }
      )

      scheduler.send(:finalize_heartbeat, state)

      assert_not state.running
      assert_equal 3, state.run_count
      assert_nil state.run_thread
      assert_not_nil state.last_completed_at
      assert_not_nil state.next_run_at
    end

    test "permission_config returns nil for auto mode" do
      scheduler = build_scheduler
      definition = build_definition(permission_mode: :auto)
      opts = scheduler.send(:heartbeat_session_opts, definition)
      assert_nil opts[:permission_config]
    end

    test "permission_config returns McpConfig for interactive mode" do
      ENV["EARL_SKIP_PERMISSIONS"] = "false"
      scheduler = build_scheduler
      definition = build_definition(permission_mode: :interactive)
      opts = scheduler.send(:heartbeat_session_opts, definition)
      config = opts[:permission_config]
      assert_instance_of Earl::ClaudeSession::McpConfig, config
      assert_equal "https://mattermost.example.com", config.env["PLATFORM_URL"]
      assert_equal "test-token", config.env["PLATFORM_TOKEN"]
    end

    test "start initializes states and starts scheduler thread" do
      definition = build_definition(name: "test_beat", interval: 60)
      heartbeat_config = Object.new
      heartbeat_config.define_singleton_method(:definitions) { [definition] }

      scheduler = build_scheduler(heartbeat_config: heartbeat_config)
      scheduler.start

      # Verify thread was started
      thread = scheduler.instance_variable_get(:@control).scheduler_thread
      assert_not_nil thread
      assert thread.alive?

      # Verify states were initialized
      states = scheduler.instance_variable_get(:@states)
      assert_equal 1, states.size
      assert states.key?("test_beat")
      assert_not_nil states["test_beat"].next_run_at
    ensure
      scheduler&.stop
    end

    test "initialize_states sets next_run_at for each definition" do
      scheduler = build_scheduler
      defs = [
        build_definition(name: "beat_1", interval: 60),
        build_definition(name: "beat_2", cron: "0 9 * * *", interval: nil)
      ]

      scheduler.send(:initialize_states, defs)

      states = scheduler.instance_variable_get(:@states)
      assert_equal 2, states.size
      assert_not_nil states["beat_1"].next_run_at
      assert_not_nil states["beat_2"].next_run_at
      assert_equal 0, states["beat_1"].run_count
      assert_equal false, states["beat_1"].running
    end

    test "check_and_dispatch dispatches due heartbeats" do
      scheduler = build_scheduler
      definition = build_definition(name: "due_beat")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: false, run_count: 0,
        next_run_at: Time.now - 60
      )
      scheduler.instance_variable_get(:@states)["due_beat"] = state

      # Stub execute_heartbeat to avoid real Claude session
      scheduler.define_singleton_method(:execute_heartbeat) { |_state| }

      scheduler.send(:check_and_dispatch)

      assert state.running
      assert_not_nil state.last_run_at
      assert_not_nil state.run_thread
    ensure
      state.run_thread&.join(1)
    end

    test "dispatch_heartbeat sets running state and spawns thread" do
      scheduler = build_scheduler
      definition = build_definition(name: "test")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: false, run_count: 0
      )

      # Stub execute_heartbeat to avoid real execution
      scheduler.define_singleton_method(:execute_heartbeat) { |_state| }

      scheduler.send(:dispatch_heartbeat, state, Time.now)

      assert state.running
      assert_not_nil state.last_run_at
      assert_not_nil state.run_thread
    ensure
      state.run_thread&.join(1)
    end

    test "execute_heartbeat creates header post and runs session" do
      posted = []
      mock_mm = build_mock_mattermost(posted: posted)
      scheduler = build_scheduler(mattermost: mock_mm)

      definition = build_definition(name: "exec_test", timeout: 5)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0
      )

      # Stub session creation and run
      scheduler.define_singleton_method(:build_heartbeat_session) do |_def, _state|
        session = Object.new
        session.define_singleton_method(:on_text) { |&_block| }
        session.define_singleton_method(:on_complete) { |&block| block.call(nil) } # complete immediately
        session.define_singleton_method(:on_tool_use) { |&_block| }
        session.define_singleton_method(:start) {}
        session.define_singleton_method(:send_message) { |_text| }
        session.define_singleton_method(:session_id) { "test-session" }
        session
      end

      scheduler.send(:execute_heartbeat, state)

      # Header post should have been created
      assert_equal 1, posted.size
      assert_includes posted.first[:message], "Test heartbeat"
    end

    test "execute_heartbeat returns early when header post is nil" do
      mock_mm = Object.new
      mock_mm.define_singleton_method(:create_post) { |**_args| nil }
      mock_mm.define_singleton_method(:send_typing) { |**_args| }

      scheduler = build_scheduler(mattermost: mock_mm)
      definition = build_definition(name: "no_header")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0
      )

      session_created = false
      scheduler.define_singleton_method(:build_heartbeat_session) { |_def, _state| session_created = true }

      scheduler.send(:execute_heartbeat, state)

      assert_not session_created
    end

    test "execute_heartbeat handles errors and sets last_error" do
      posted = []
      mock_mm = build_mock_mattermost(posted: posted)
      scheduler = build_scheduler(mattermost: mock_mm)

      definition = build_definition(name: "error_test")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0
      )

      scheduler.define_singleton_method(:build_heartbeat_session) { |_def, _state| raise "session error" }

      scheduler.send(:execute_heartbeat, state)

      assert_equal "session error", state.last_error
      assert_not state.running # finalize was called
      assert_equal 1, state.run_count
    end

    test "await_heartbeat_completion returns when heartbeat completes" do
      scheduler = build_scheduler
      session = Object.new
      session.define_singleton_method(:kill) {}

      completed = false
      Thread.new do
        sleep 0.1
        completed = true
      end

      scheduler.send(:await_heartbeat_completion, session, 10) { completed }
      assert completed
    end

    test "await_heartbeat_completion kills session on timeout" do
      scheduler = build_scheduler

      killed = false
      session = Object.new
      session.define_singleton_method(:kill) { killed = true }

      scheduler.send(:await_heartbeat_completion, session, 1) { false }
      assert killed
    end

    test "start always creates scheduler thread even with empty definitions" do
      scheduler = build_scheduler(heartbeat_config: empty_config)
      scheduler.start
      thread = scheduler.instance_variable_get(:@control).scheduler_thread
      assert_not_nil thread
      assert thread.alive?
    ensure
      scheduler&.stop
    end

    test "stop kills scheduler thread" do
      scheduler = build_scheduler
      control = scheduler.instance_variable_get(:@control)
      thread = Thread.new { sleep 0.01 until control.stop_requested }
      control.scheduler_thread = thread

      scheduler.stop
      sleep 0.05

      assert_not thread.alive?
      assert_nil scheduler.instance_variable_get(:@control).scheduler_thread
    end

    test "stop kills running heartbeat threads" do
      scheduler = build_scheduler
      control = scheduler.instance_variable_get(:@control)
      # Thread exits when stop_requested is set (before join times out)
      heartbeat_thread = Thread.new { sleep 0.01 until control.stop_requested }
      definition = build_definition
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0, run_thread: heartbeat_thread
      )
      scheduler.instance_variable_get(:@states)["test"] = state

      scheduler.stop
      sleep 0.05

      assert_not heartbeat_thread.alive?
    end

    test "overlap prevention: dispatch_heartbeat skips running heartbeat" do
      scheduler = build_scheduler
      definition = build_definition
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0,
        next_run_at: Time.now - 60
      )

      assert_not scheduler.send(:should_run?, state, Time.now)
    end

    # --- Auto-reload tests ---

    test "check_for_reload is no-op when mtime unchanged" do
      tmp = Dir.mktmpdir("earl-scheduler-reload-test")
      config_path = File.join(tmp, "heartbeats.yml")
      File.write(config_path, YAML.dump("heartbeats" => {}))

      hb_config = Earl::HeartbeatConfig.new(path: config_path)
      scheduler = build_scheduler(heartbeat_config: hb_config)
      scheduler.instance_variable_get(:@control).heartbeat_config_path = config_path
      scheduler.instance_variable_get(:@control).config_mtime = File.mtime(config_path)

      reload_called = false
      scheduler.define_singleton_method(:reload_definitions) { reload_called = true }

      scheduler.send(:check_for_reload)
      assert_not reload_called
    ensure
      FileUtils.rm_rf(tmp)
    end

    test "check_for_reload triggers reload when mtime changes" do
      tmp = Dir.mktmpdir("earl-scheduler-reload-test")
      config_path = File.join(tmp, "heartbeats.yml")
      File.write(config_path, YAML.dump("heartbeats" => {}))

      hb_config = Earl::HeartbeatConfig.new(path: config_path)
      scheduler = build_scheduler(heartbeat_config: hb_config)
      scheduler.instance_variable_get(:@control).heartbeat_config_path = config_path
      scheduler.instance_variable_get(:@control).config_mtime = Time.now - 60 # old mtime

      reload_called = false
      scheduler.define_singleton_method(:reload_definitions) { reload_called = true }

      scheduler.send(:check_for_reload)
      assert reload_called
    ensure
      FileUtils.rm_rf(tmp)
    end

    test "reload_definitions adds new heartbeats" do
      tmp = Dir.mktmpdir("earl-scheduler-reload-test")
      config_path = File.join(tmp, "heartbeats.yml")

      definition = build_definition(name: "new_beat", interval: 60)
      hb_config = Object.new
      hb_config.define_singleton_method(:definitions) { [definition] }
      hb_config.define_singleton_method(:path) { config_path }

      scheduler = build_scheduler(heartbeat_config: hb_config)
      scheduler.instance_variable_get(:@control).heartbeat_config_path = config_path

      scheduler.send(:reload_definitions)

      states = scheduler.instance_variable_get(:@states)
      assert states.key?("new_beat")
      assert_not_nil states["new_beat"].next_run_at
    ensure
      FileUtils.rm_rf(tmp)
    end

    test "reload_definitions removes deleted heartbeats" do
      scheduler = build_scheduler(heartbeat_config: empty_config_with_path)

      # Add a state manually
      definition = build_definition(name: "old_beat")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: false, run_count: 1
      )
      scheduler.instance_variable_get(:@states)["old_beat"] = state

      scheduler.send(:reload_definitions)

      states = scheduler.instance_variable_get(:@states)
      assert_not states.key?("old_beat")
    end

    test "reload_definitions preserves running heartbeat states" do
      scheduler = build_scheduler(heartbeat_config: empty_config_with_path)

      definition = build_definition(name: "running_beat")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 5
      )
      scheduler.instance_variable_get(:@states)["running_beat"] = state

      scheduler.send(:reload_definitions)

      states = scheduler.instance_variable_get(:@states)
      assert states.key?("running_beat"), "Running heartbeat should not be removed"
      assert_equal 5, states["running_beat"].run_count
    end

    test "reload_definitions updates definitions for non-running heartbeats" do
      updated_def = build_definition(name: "updatable", interval: 120)
      hb_config = Object.new
      hb_config.define_singleton_method(:definitions) { [updated_def] }
      hb_config.define_singleton_method(:path) { "/tmp/fake.yml" }

      scheduler = build_scheduler(heartbeat_config: hb_config)
      scheduler.instance_variable_get(:@control).heartbeat_config_path = "/tmp/fake.yml"

      old_def = build_definition(name: "updatable", interval: 60)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: old_def, running: false, run_count: 2
      )
      scheduler.instance_variable_get(:@states)["updatable"] = state

      scheduler.send(:reload_definitions)

      states = scheduler.instance_variable_get(:@states)
      assert_equal 120, states["updatable"].definition.interval
      assert_equal 2, states["updatable"].run_count # preserved
    end

    test "config_file_mtime returns nil for nonexistent file" do
      scheduler = build_scheduler
      scheduler.instance_variable_get(:@control).heartbeat_config_path = "/nonexistent/heartbeats.yml"

      assert_nil scheduler.send(:config_file_mtime)
    end

    test "config_file_mtime returns mtime for existing file" do
      tmp = Dir.mktmpdir("earl-scheduler-mtime-test")
      config_path = File.join(tmp, "heartbeats.yml")
      File.write(config_path, "test")

      scheduler = build_scheduler
      scheduler.instance_variable_get(:@control).heartbeat_config_path = config_path

      mtime = scheduler.send(:config_file_mtime)
      assert_instance_of Time, mtime
    ensure
      FileUtils.rm_rf(tmp)
    end

    test "build_heartbeat_session creates new session for non-persistent" do
      scheduler = build_scheduler
      definition = build_definition(persistent: false)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: false, run_count: 0
      )

      session = scheduler.send(:build_heartbeat_session, definition, state)
      assert_instance_of Earl::ClaudeSession, session
      assert_not_nil session.session_id
    end

    test "build_heartbeat_session reuses session_id for persistent" do
      scheduler = build_scheduler
      definition = build_definition(persistent: true)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: false, run_count: 1,
        session_id: "existing-session-id"
      )

      session = scheduler.send(:build_heartbeat_session, definition, state)
      assert_equal "existing-session-id", session.session_id
    end

    test "compute_next_run with future run_at returns that time" do
      scheduler = build_scheduler
      future_ts = (Time.now + 3600).to_i
      definition = build_definition(run_at: future_ts, interval: nil)
      now = Time.now

      next_run = scheduler.send(:compute_next_run, definition, now)
      assert_equal Time.at(future_ts), next_run
    end

    test "compute_next_run with past run_at returns from time" do
      scheduler = build_scheduler
      past_ts = (Time.now - 3600).to_i
      definition = build_definition(run_at: past_ts, interval: nil)
      now = Time.now

      next_run = scheduler.send(:compute_next_run, definition, now)
      assert_equal now, next_run
    end

    test "compute_next_run run_at takes priority over cron and interval" do
      scheduler = build_scheduler
      future_ts = (Time.now + 7200).to_i
      definition = build_definition(run_at: future_ts, cron: "0 9 * * *", interval: 60)
      now = Time.now

      next_run = scheduler.send(:compute_next_run, definition, now)
      assert_equal Time.at(future_ts), next_run
    end

    test "finalize_heartbeat with once true sets next_run_at to nil and disables" do
      tmp = Dir.mktmpdir("earl-scheduler-once-test")
      config_path = File.join(tmp, "heartbeats.yml")
      File.write(config_path, YAML.dump(
                                "heartbeats" => {
                                  "one_shot" => {
                                    "schedule" => { "run_at" => Time.now.to_i },
                                    "channel_id" => "ch", "prompt" => "p",
                                    "once" => true, "enabled" => true
                                  }
                                }
                              ))

      hb_config = Earl::HeartbeatConfig.new(path: config_path)
      scheduler = build_scheduler(heartbeat_config: hb_config)
      scheduler.instance_variable_get(:@control).heartbeat_config_path = config_path

      definition = build_definition(name: "one_shot", once: true, run_at: Time.now.to_i, interval: nil)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0,
        run_thread: Thread.new { sleep 0 }
      )

      scheduler.send(:finalize_heartbeat, state)

      assert_nil state.next_run_at
      assert_not state.running
      assert_equal 1, state.run_count

      # Verify YAML was updated
      data = YAML.safe_load_file(config_path)
      assert_equal false, data["heartbeats"]["one_shot"]["enabled"]
    ensure
      FileUtils.rm_rf(tmp)
    end

    test "finalize_heartbeat with once false computes next run normally" do
      scheduler = build_scheduler
      definition = build_definition(interval: 60, once: false)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 2,
        run_thread: Thread.new { sleep 0 }
      )

      scheduler.send(:finalize_heartbeat, state)

      assert_not state.running
      assert_equal 3, state.run_count
      assert_not_nil state.next_run_at
    end

    test "disable_heartbeat writes enabled false to YAML" do
      tmp = Dir.mktmpdir("earl-scheduler-disable-test")
      config_path = File.join(tmp, "heartbeats.yml")
      File.write(config_path, YAML.dump(
                                "heartbeats" => {
                                  "my_beat" => {
                                    "schedule" => { "run_at" => 1_700_000_000 },
                                    "channel_id" => "ch", "prompt" => "p",
                                    "once" => true, "enabled" => true
                                  }
                                }
                              ))

      scheduler = build_scheduler
      scheduler.instance_variable_get(:@control).heartbeat_config_path = config_path

      scheduler.send(:disable_heartbeat, "my_beat")

      data = YAML.safe_load_file(config_path)
      assert_equal false, data["heartbeats"]["my_beat"]["enabled"]
    ensure
      FileUtils.rm_rf(tmp)
    end

    test "disable_heartbeat handles missing file gracefully" do
      scheduler = build_scheduler
      scheduler.instance_variable_get(:@control).heartbeat_config_path = "/nonexistent/heartbeats.yml"

      # Should not raise
      assert_nothing_raised { scheduler.send(:disable_heartbeat, "ghost") }
    end

    test "disable_heartbeat handles missing heartbeat name in config gracefully" do
      tmp = Dir.mktmpdir("earl-scheduler-disable-test")
      config_path = File.join(tmp, "heartbeats.yml")
      File.write(config_path, YAML.dump("heartbeats" => {}))

      scheduler = build_scheduler
      scheduler.instance_variable_get(:@control).heartbeat_config_path = config_path

      # Should not raise
      assert_nothing_raised { scheduler.send(:disable_heartbeat, "nonexistent") }
    ensure
      FileUtils.rm_rf(tmp)
    end

    test "update_definition_if_idle skips update when running" do
      build_scheduler
      definition = build_definition(name: "busy", interval: 60)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 1
      )

      new_def = build_definition(name: "busy", interval: 120)
      state.update_definition_if_idle(new_def)

      assert_equal 60, state.definition.interval
    end

    test "update_definition_if_idle updates when not running" do
      build_scheduler
      definition = build_definition(name: "idle", interval: 60)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: false, run_count: 1
      )

      new_def = build_definition(name: "idle", interval: 120)
      state.update_definition_if_idle(new_def)

      assert_equal 120, state.definition.interval
    end

    test "compute_next_run returns nil when no schedule type is set" do
      scheduler = build_scheduler
      definition = build_definition(interval: nil, cron: nil, run_at: nil)

      next_run = scheduler.send(:compute_next_run, definition, Time.now)
      assert_nil next_run
    end

    test "apply_resume_opts skips when no session_id saved" do
      scheduler = build_scheduler
      definition = build_definition(persistent: true)
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: false, run_count: 0,
        session_id: nil
      )

      opts = {}
      scheduler.send(:apply_resume_opts, opts, state)
      assert_not opts.key?(:session_id)
      assert_not opts.key?(:mode)
    end

    test "disable_entry returns false when yaml_data is not a hash" do
      scheduler = build_scheduler
      result = scheduler.send(:disable_entry, "not a hash", "test_beat")
      assert_equal false, result
    end

    test "disable_entry returns false when heartbeat name not found" do
      scheduler = build_scheduler
      result = scheduler.send(:disable_entry, { "heartbeats" => {} }, "nonexistent")
      assert_equal false, result
    end

    test "stop handles thread that is no longer alive" do
      scheduler = build_scheduler
      thread = Thread.new { nil } # exits immediately
      thread.join
      scheduler.instance_variable_get(:@control).scheduler_thread = thread

      assert_nothing_raised { scheduler.stop }
      assert_nil scheduler.instance_variable_get(:@control).scheduler_thread
    end

    test "update_existing_definitions skips when state is nil for new definition" do
      scheduler = build_scheduler
      new_def = build_definition(name: "brand_new", interval: 60)

      # states hash is empty, so @states["brand_new"] is nil
      assert_nothing_raised { scheduler.send(:update_existing_definitions, [new_def]) }
    end

    test "stop handles nil scheduler thread" do
      scheduler = build_scheduler
      scheduler.instance_variable_get(:@control).scheduler_thread = nil

      assert_nothing_raised { scheduler.stop }
    end

    test "stop handles run threads that are no longer alive" do
      scheduler = build_scheduler
      dead_thread = Thread.new { nil }
      dead_thread.join

      definition = build_definition
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0, run_thread: dead_thread
      )
      scheduler.instance_variable_get(:@states)["test"] = state

      assert_nothing_raised { scheduler.stop }
    end

    test "scheduler_loop rescues errors and continues" do
      scheduler = build_scheduler

      call_count = 0
      scheduler.define_singleton_method(:check_for_reload) do
        call_count += 1
        raise "simulated error" if call_count == 1
      end
      scheduler.define_singleton_method(:check_and_dispatch) {}

      control = scheduler.instance_variable_get(:@control)
      control.stop_requested = false

      thread = Thread.new { scheduler.send(:scheduler_loop) }
      sleep 0.05
      control.stop_requested = true
      thread.join(1)

      assert call_count >= 1, "scheduler_loop should have rescued and retried"
    end

    test "check_and_dispatch skips heartbeat when should_run? is false" do
      scheduler = build_scheduler
      definition = build_definition(name: "not_due")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: false, run_count: 0,
        next_run_at: Time.now + 9999
      )
      scheduler.instance_variable_get(:@states)["not_due"] = state

      dispatched = false
      scheduler.define_singleton_method(:dispatch_heartbeat) { |_s, _t| dispatched = true }

      scheduler.send(:check_and_dispatch)
      assert_not dispatched
    end

    test "join_and_kill_thread kills thread that is still alive after join timeout" do
      scheduler = build_scheduler
      # Create a thread that blocks until explicitly killed
      thread = Thread.new { sleep 999 }

      # Speed up join timeout from 5s to 0.01s
      original_join = thread.method(:join)
      thread.define_singleton_method(:join) { |_timeout = nil| original_join.call(0.01) }

      scheduler.send(:join_and_kill_thread, thread)
      sleep 0.05

      assert_not thread.alive?, "Thread should be killed after join timeout"
    end

    test "stop_heartbeat_threads kills threads that are still alive after join" do
      scheduler = build_scheduler
      # Create a thread that blocks until explicitly killed
      blocking_thread = Thread.new { sleep 999 }

      # Speed up join timeout from 3s to 0.01s
      original_join = blocking_thread.method(:join)
      blocking_thread.define_singleton_method(:join) { |_timeout = nil| original_join.call(0.01) }

      definition = build_definition
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0, run_thread: blocking_thread
      )
      scheduler.instance_variable_get(:@states)["blocking"] = state

      scheduler.send(:stop_heartbeat_threads)
      sleep 0.05

      assert_not blocking_thread.alive?, "Heartbeat thread should be killed after join timeout"
    end

    test "handle_heartbeat_error with backtrace logs backtrace lines" do
      scheduler = build_scheduler
      definition = build_definition(name: "err")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0
      )

      error = StandardError.new("boom")
      error.set_backtrace(["line1.rb:1", "line2.rb:2", "line3.rb:3"])
      scheduler.send(:handle_heartbeat_error, state, "err", error)

      assert_equal "boom", state.last_error
    end

    test "handle_heartbeat_error with nil backtrace does not raise" do
      scheduler = build_scheduler
      definition = build_definition(name: "err")
      state = Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: true, run_count: 0
      )

      error = StandardError.new("no trace")
      # backtrace is nil by default for newly created errors
      assert_nothing_raised { scheduler.send(:handle_heartbeat_error, state, "err", error) }
    end

    private

    def build_scheduler(mattermost: nil, heartbeat_config: nil)
      config = Earl::Config.new
      mock_mm = mattermost || build_mock_mattermost

      scheduler = Earl::HeartbeatScheduler.new(
        config: config, mattermost: mock_mm
      )
      scheduler.instance_variable_get(:@deps).heartbeat_config = heartbeat_config if heartbeat_config
      scheduler
    end

    def build_mock_mattermost(posted: [])
      pstd = posted
      mock = Object.new
      mock.define_singleton_method(:create_post) do |channel_id:, message:, root_id: nil|
        pstd << { channel_id: channel_id, message: message, root_id: root_id }
        { "id" => "header-post-1" }
      end
      mock.define_singleton_method(:send_typing) { |**_args| }
      mock.define_singleton_method(:update_post) { |**_args| }
      mock
    end

    def build_definition(name: "test_beat", description: "Test heartbeat", cron: nil,
                         interval: 60, run_at: nil, channel_id: "channel-456", permission_mode: :auto,
                         persistent: false, timeout: 300, once: false)
      Earl::HeartbeatConfig::HeartbeatDefinition.new(
        name: name, description: description, cron: cron, interval: interval,
        run_at: run_at, channel_id: channel_id, working_dir: "/tmp", prompt: "Test prompt.",
        permission_mode: permission_mode, persistent: persistent, timeout: timeout,
        enabled: true, once: once
      )
    end

    def build_state(running: false, next_run_at: nil)
      definition = build_definition
      Earl::HeartbeatScheduler::HeartbeatState.new(
        definition: definition, running: running, run_count: 0,
        next_run_at: next_run_at
      )
    end

    def empty_config
      mock = Object.new
      mock.define_singleton_method(:definitions) { [] }
      mock.define_singleton_method(:path) { "/tmp/nonexistent-heartbeats.yml" }
      mock
    end

    def empty_config_with_path
      mock = Object.new
      mock.define_singleton_method(:definitions) { [] }
      mock.define_singleton_method(:path) { "/tmp/nonexistent-heartbeats.yml" }
      mock
    end
  end
end
