require "test_helper"

class Earl::SessionManagerTest < ActiveSupport::TestCase
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

  test "get_or_create creates new session for unknown thread" do
    manager = Earl::SessionManager.new
    session = create_with_fake_session(manager, "thread-abc12345")

    assert_not_nil session
  end

  test "get_or_create reuses alive session for same thread" do
    manager = Earl::SessionManager.new
    first = create_with_fake_session(manager, "thread-abc12345", alive: true)
    second = manager.get_or_create("thread-abc12345")

    assert_same first, second
  end

  test "get_or_create replaces dead session" do
    manager = Earl::SessionManager.new
    first = create_with_fake_session(manager, "thread-abc12345", alive: false)

    # Second call should create a new session since first is dead
    second = create_with_fake_session(manager, "thread-abc12345")

    assert_not_same first, second
  end

  test "stop_all kills all sessions and clears map" do
    manager = Earl::SessionManager.new
    killed = []

    s1 = create_with_fake_session(manager, "thread-aaa11111") { killed << :a }
    s2 = create_with_fake_session(manager, "thread-bbb22222") { killed << :b }
    s3 = create_with_fake_session(manager, "thread-ccc33333") { killed << :c }

    manager.stop_all

    assert_equal 3, killed.size

    # After stop_all, new requests should create fresh sessions
    fresh = create_with_fake_session(manager, "thread-aaa11111")
    assert_not_same s1, fresh
  end

  test "get returns session for known thread" do
    manager = Earl::SessionManager.new
    session = create_with_fake_session(manager, "thread-abc12345", alive: true)

    assert_same session, manager.get("thread-abc12345")
  end

  test "get returns nil for unknown thread" do
    manager = Earl::SessionManager.new
    assert_nil manager.get("thread-unknown123")
  end

  test "stop_session kills and removes single session" do
    manager = Earl::SessionManager.new
    killed = false
    create_with_fake_session(manager, "thread-abc12345") { killed = true }

    manager.stop_session("thread-abc12345")

    assert killed
    assert_nil manager.get("thread-abc12345")
  end

  test "stop_session handles unknown thread gracefully" do
    manager = Earl::SessionManager.new
    assert_nothing_raised { manager.stop_session("thread-unknown123") }
  end

  test "get_or_create with permission config builds permission env" do
    config = Earl::Config.new
    manager = Earl::SessionManager.new(config: config)

    session = create_with_fake_session(manager, "thread-abc12345")
    assert_not_nil session
  end

  test "pause_all kills all sessions" do
    manager = Earl::SessionManager.new
    killed = []
    create_with_fake_session(manager, "thread-aaa11111") { killed << :a }
    create_with_fake_session(manager, "thread-bbb22222") { killed << :b }

    manager.pause_all

    assert_equal 2, killed.size
    assert_nil manager.get("thread-aaa11111")
  end

  test "touch delegates to session_store" do
    touched = []
    mock_store = Object.new
    mock_store.define_singleton_method(:touch) { |thread_id| touched << thread_id }
    mock_store.define_singleton_method(:save) { |*_args| }

    manager = Earl::SessionManager.new(session_store: mock_store)
    manager.touch("thread-abc12345")

    assert_equal [ "thread-abc12345" ], touched
  end

  test "touch does nothing without session_store" do
    manager = Earl::SessionManager.new
    assert_nothing_raised { manager.touch("thread-abc12345") }
  end

  test "resume_all does nothing without session_store" do
    manager = Earl::SessionManager.new
    assert_nothing_raised { manager.resume_all }
  end

  test "resume_all resumes non-paused sessions from store" do
    # Create a store with a persisted session
    store = Object.new
    loaded_data = {
      "thread-abc12345" => Earl::SessionStore::PersistedSession.new(
        claude_session_id: "sess-123",
        channel_id: "channel-1",
        working_dir: "/tmp",
        started_at: Time.now.iso8601,
        last_activity_at: Time.now.iso8601,
        is_paused: false,
        message_count: 0
      )
    }
    store.define_singleton_method(:load) { loaded_data }

    config = Earl::Config.new
    manager = Earl::SessionManager.new(config: config, session_store: store)

    # Mock ClaudeSession to track creation
    started = []
    original_new = Earl::ClaudeSession.method(:new)
    Earl::ClaudeSession.define_singleton_method(:new) do |**args|
      session = Object.new
      session.define_singleton_method(:start) { started << args }
      session.define_singleton_method(:alive?) { true }
      session.define_singleton_method(:session_id) { args[:session_id] }
      session.define_singleton_method(:kill) { }
      session
    end

    manager.resume_all

    assert_equal 1, started.size
    assert_equal "sess-123", started.first[:session_id]
    assert_equal :resume, started.first[:mode]
  ensure
    Earl::ClaudeSession.define_singleton_method(:new) { |**args| original_new.call(**args) } if original_new
  end

  test "resume_all skips paused sessions" do
    store = Object.new
    loaded_data = {
      "thread-paused" => Earl::SessionStore::PersistedSession.new(
        claude_session_id: "sess-456",
        channel_id: "channel-1",
        working_dir: "/tmp",
        started_at: Time.now.iso8601,
        last_activity_at: Time.now.iso8601,
        is_paused: true,
        message_count: 0
      )
    }
    store.define_singleton_method(:load) { loaded_data }

    manager = Earl::SessionManager.new(session_store: store)
    manager.resume_all

    assert_nil manager.get("thread-paused")
  end

  test "get_or_create resumes from store when session is dead" do
    store = Object.new
    loaded_data = {
      "thread-abc12345" => Earl::SessionStore::PersistedSession.new(
        claude_session_id: "sess-original",
        channel_id: "channel-1",
        working_dir: "/tmp",
        started_at: Time.now.iso8601,
        last_activity_at: Time.now.iso8601,
        is_paused: false,
        message_count: 0
      )
    }
    store.define_singleton_method(:load) { loaded_data }
    store.define_singleton_method(:save) { |*_args| }

    config = Earl::Config.new
    manager = Earl::SessionManager.new(config: config, session_store: store)

    # First, create a session that's dead
    dead_session = fake_session(alive: false)
    original_new = Earl::ClaudeSession.method(:new)

    call_count = 0
    Earl::ClaudeSession.define_singleton_method(:new) do |**args|
      call_count += 1
      session = Object.new
      session.define_singleton_method(:start) { }
      session.define_singleton_method(:alive?) { call_count > 1 } # first is dead, second is alive (resumed)
      session.define_singleton_method(:session_id) { args[:session_id] || "new-session" }
      session.define_singleton_method(:kill) { }
      session
    end

    # First get_or_create — creates a dead session
    first = manager.get_or_create("thread-abc12345")

    # Second get_or_create — session is dead, should resume from store
    second = manager.get_or_create("thread-abc12345")

    # The resumed session should have the original session_id
    assert_equal "sess-original", second.session_id
  ensure
    Earl::ClaudeSession.define_singleton_method(:new) { |**args| original_new.call(**args) } if original_new
  end

  test "get_or_create falls back to new session when resume fails" do
    store = Object.new
    loaded_data = {
      "thread-abc12345" => Earl::SessionStore::PersistedSession.new(
        claude_session_id: "sess-broken",
        channel_id: "channel-1",
        working_dir: "/tmp",
        started_at: Time.now.iso8601,
        last_activity_at: Time.now.iso8601,
        is_paused: false,
        message_count: 0
      )
    }
    store.define_singleton_method(:load) { loaded_data }
    store.define_singleton_method(:save) { |*_args| }

    config = Earl::Config.new
    manager = Earl::SessionManager.new(config: config, session_store: store)

    original_new = Earl::ClaudeSession.method(:new)
    call_count = 0
    Earl::ClaudeSession.define_singleton_method(:new) do |**args|
      call_count += 1
      if call_count == 1
        # Resume attempt fails
        session = Object.new
        session.define_singleton_method(:start) { raise "resume failed" }
        session.define_singleton_method(:alive?) { false }
        session.define_singleton_method(:session_id) { "sess-broken" }
        session.define_singleton_method(:kill) { }
        session
      else
        # Fallback to new session succeeds
        session = Object.new
        session.define_singleton_method(:start) { }
        session.define_singleton_method(:alive?) { true }
        session.define_singleton_method(:session_id) { "sess-new" }
        session.define_singleton_method(:kill) { }
        session
      end
    end

    result = manager.get_or_create("thread-abc12345")

    # Should have fallen back to a new session
    assert_equal "sess-new", result.session_id
  ensure
    Earl::ClaudeSession.define_singleton_method(:new) { |**args| original_new.call(**args) } if original_new
  end

  test "resume_session handles errors gracefully on startup" do
    store = Object.new
    loaded_data = {
      "thread-abc12345" => Earl::SessionStore::PersistedSession.new(
        claude_session_id: "sess-broken",
        channel_id: "channel-1",
        working_dir: "/tmp",
        started_at: Time.now.iso8601,
        last_activity_at: Time.now.iso8601,
        is_paused: false,
        message_count: 0
      )
    }
    store.define_singleton_method(:load) { loaded_data }

    config = Earl::Config.new
    manager = Earl::SessionManager.new(config: config, session_store: store)

    original_new = Earl::ClaudeSession.method(:new)
    Earl::ClaudeSession.define_singleton_method(:new) do |**_args|
      session = Object.new
      session.define_singleton_method(:start) { raise "connection refused" }
      session
    end

    # Should not raise
    assert_nothing_raised { manager.resume_all }

    # Session should not have been stored
    assert_nil manager.get("thread-abc12345")
  ensure
    Earl::ClaudeSession.define_singleton_method(:new) { |**args| original_new.call(**args) } if original_new
  end

  test "stop_session calls remove on session_store when present" do
    removed = []
    mock_store = Object.new
    mock_store.define_singleton_method(:remove) { |thread_id| removed << thread_id }
    mock_store.define_singleton_method(:save) { |*_args| }
    mock_store.define_singleton_method(:load) { {} }

    manager = Earl::SessionManager.new(session_store: mock_store)
    killed = false
    session = fake_session { killed = true }

    original_new = Earl::ClaudeSession.method(:new)
    Earl::ClaudeSession.define_singleton_method(:new) { |**_args| session }
    manager.get_or_create("thread-abc12345")
    Earl::ClaudeSession.define_singleton_method(:new) { |**args| original_new.call(**args) }

    manager.stop_session("thread-abc12345")

    assert killed
    assert_equal [ "thread-abc12345" ], removed
  end

  test "pause_all saves paused state to session_store" do
    saved = []
    mock_store = Object.new
    mock_store.define_singleton_method(:save) { |thread_id, persisted| saved << { thread_id: thread_id, paused: persisted.is_paused } }
    mock_store.define_singleton_method(:load) { {} }

    manager = Earl::SessionManager.new(session_store: mock_store)

    session = fake_session
    original_new = Earl::ClaudeSession.method(:new)
    Earl::ClaudeSession.define_singleton_method(:new) { |**_args| session }
    manager.get_or_create("thread-abc12345")
    Earl::ClaudeSession.define_singleton_method(:new) { |**args| original_new.call(**args) }

    saved.clear
    manager.pause_all

    assert_equal 1, saved.size
    assert_equal "thread-abc12345", saved.first[:thread_id]
    assert saved.first[:paused], "Expected session to be saved as paused"
  end

  test "build_permission_config returns config hash when skip_permissions is false" do
    ENV["EARL_SKIP_PERMISSIONS"] = nil
    ENV.delete("EARL_SKIP_PERMISSIONS")
    config = Earl::Config.new
    manager = Earl::SessionManager.new(config: config)

    result = manager.send(:build_permission_config, "thread-123", "channel-456")
    assert_not_nil result
    assert_equal "https://mattermost.example.com", result["PLATFORM_URL"]
    assert_equal "test-token", result["PLATFORM_TOKEN"]
    assert_equal "channel-456", result["PLATFORM_CHANNEL_ID"]
    assert_equal "thread-123", result["PLATFORM_THREAD_ID"]
    assert_equal "bot-123", result["PLATFORM_BOT_ID"]
  end

  private

  def create_with_fake_session(manager, thread_id, alive: true, &on_kill)
    # Temporarily replace the session creation in get_or_create
    # by pre-populating and using the manager's internal map
    session = fake_session(alive: alive, &on_kill)

    # Access internal state to inject our fake
    original_new = Earl::ClaudeSession.method(:new)
    Earl::ClaudeSession.define_singleton_method(:new) { |**_args| session }

    result = manager.get_or_create(thread_id)

    Earl::ClaudeSession.define_singleton_method(:new) { |**args| original_new.call(**args) }

    result
  end

  def fake_session(alive: true, &on_kill)
    session = Object.new
    session.define_singleton_method(:start) { }
    session.define_singleton_method(:alive?) { alive }
    session.define_singleton_method(:kill) { on_kill&.call }
    session.define_singleton_method(:session_id) { "fake-session-id" }
    session.define_singleton_method(:total_cost) { 0.0 }
    session
  end
end
