# frozen_string_literal: true

require "test_helper"

class Earl::HeartbeatSchedulerTest < ActiveSupport::TestCase
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
  end

  teardown do
    Earl.logger = nil
    %w[MATTERMOST_URL MATTERMOST_BOT_TOKEN MATTERMOST_BOT_ID EARL_CHANNEL_ID EARL_ALLOWED_USERS EARL_SKIP_PERMISSIONS].each do |key|
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
    result = scheduler.send(:create_header_post, definition)

    assert_equal 1, posted.size
    assert_includes posted.first[:message], "Morning briefing"
    assert_includes posted.first[:message], "🫀"
    assert_equal({ "id" => "header-post-1" }, result)
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
    assert_nil scheduler.send(:permission_config, definition)
  end

  test "permission_config returns hash for interactive mode" do
    scheduler = build_scheduler
    definition = build_definition(permission_mode: :interactive)
    config = scheduler.send(:permission_config, definition)
    assert_equal "https://mattermost.example.com", config["PLATFORM_URL"]
    assert_equal "test-token", config["PLATFORM_TOKEN"]
  end

  test "start initializes states and starts scheduler thread" do
    definition = build_definition(name: "test_beat", interval: 60)
    heartbeat_config = Object.new
    heartbeat_config.define_singleton_method(:definitions) { [ definition ] }

    scheduler = build_scheduler(heartbeat_config: heartbeat_config)
    scheduler.start

    # Verify thread was started
    thread = scheduler.instance_variable_get(:@scheduler_thread)
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
    scheduler.define_singleton_method(:create_heartbeat_session) do |_def, _state|
      session = Object.new
      session.define_singleton_method(:on_text) { |&_block| }
      session.define_singleton_method(:on_complete) { |&block| block.call(nil) } # complete immediately
      session.define_singleton_method(:on_tool_use) { |&_block| }
      session.define_singleton_method(:start) { }
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
    scheduler.define_singleton_method(:create_heartbeat_session) { |_def, _state| session_created = true }

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

    scheduler.define_singleton_method(:create_heartbeat_session) { |_def, _state| raise "session error" }

    scheduler.send(:execute_heartbeat, state)

    assert_equal "session error", state.last_error
    assert_not state.running # finalize was called
    assert_equal 1, state.run_count
  end

  test "wait_for_completion returns when block yields true" do
    scheduler = build_scheduler
    definition = build_definition(timeout: 10)
    session = Object.new
    session.define_singleton_method(:kill) { }

    completed = false
    Thread.new { sleep 0.1; completed = true }

    scheduler.send(:wait_for_completion, session, definition, nil) { completed }
    assert completed
  end

  test "wait_for_completion kills session on timeout" do
    scheduler = build_scheduler
    definition = build_definition(timeout: 1)

    killed = false
    session = Object.new
    session.define_singleton_method(:kill) { killed = true }

    scheduler.send(:wait_for_completion, session, definition, nil) { false }
    assert killed
  end

  test "start does nothing when no definitions" do
    scheduler = build_scheduler(heartbeat_config: empty_config)
    scheduler.start
    assert_nil scheduler.instance_variable_get(:@scheduler_thread)
  end

  test "stop kills scheduler thread" do
    scheduler = build_scheduler
    thread = Thread.new { sleep 60 }
    scheduler.instance_variable_set(:@scheduler_thread, thread)

    scheduler.stop
    sleep 0.05

    assert_not thread.alive?
    assert_nil scheduler.instance_variable_get(:@scheduler_thread)
  end

  test "stop kills running heartbeat threads" do
    scheduler = build_scheduler
    heartbeat_thread = Thread.new { sleep 60 }
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

  test "create_heartbeat_session creates new session for non-persistent" do
    scheduler = build_scheduler
    definition = build_definition(persistent: false)
    state = Earl::HeartbeatScheduler::HeartbeatState.new(
      definition: definition, running: false, run_count: 0
    )

    session = scheduler.send(:create_heartbeat_session, definition, state)
    assert_instance_of Earl::ClaudeSession, session
    assert_not_nil session.session_id
  end

  test "create_heartbeat_session reuses session_id for persistent" do
    scheduler = build_scheduler
    definition = build_definition(persistent: true)
    state = Earl::HeartbeatScheduler::HeartbeatState.new(
      definition: definition, running: false, run_count: 1,
      session_id: "existing-session-id"
    )

    session = scheduler.send(:create_heartbeat_session, definition, state)
    assert_equal "existing-session-id", session.session_id
  end

  private

  def build_scheduler(mattermost: nil, heartbeat_config: nil)
    config = Earl::Config.new
    session_manager = Object.new
    session_manager.define_singleton_method(:get_or_create) { |*_args, **_kwargs| nil }
    mock_mm = mattermost || build_mock_mattermost

    scheduler = Earl::HeartbeatScheduler.new(
      config: config, session_manager: session_manager, mattermost: mock_mm
    )
    scheduler.instance_variable_set(:@heartbeat_config, heartbeat_config) if heartbeat_config
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
                        interval: 60, channel_id: "channel-456", permission_mode: :auto,
                        persistent: false, timeout: 300)
    Earl::HeartbeatConfig::HeartbeatDefinition.new(
      name: name, description: description, cron: cron, interval: interval,
      channel_id: channel_id, working_dir: "/tmp", prompt: "Test prompt.",
      permission_mode: permission_mode, persistent: persistent, timeout: timeout,
      enabled: true
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
    mock
  end
end
