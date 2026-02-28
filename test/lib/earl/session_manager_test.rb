# frozen_string_literal: true

require "test_helper"

module Earl
  class SessionManagerTest < Minitest::Test
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
      %w[MATTERMOST_URL MATTERMOST_BOT_TOKEN MATTERMOST_BOT_ID EARL_CHANNEL_ID EARL_ALLOWED_USERS
         EARL_SKIP_PERMISSIONS].each do |key|
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
      second = manager.get_or_create("thread-abc12345", default_session_config)

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
      create_with_fake_session(manager, "thread-bbb22222") { killed << :b }
      create_with_fake_session(manager, "thread-ccc33333") { killed << :c }

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
      stub_singleton(mock_store, :touch) { |thread_id| touched << thread_id }
      stub_singleton(mock_store, :save) { |*_args| }

      manager = Earl::SessionManager.new(session_store: mock_store)
      manager.touch("thread-abc12345")

      assert_equal ["thread-abc12345"], touched
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
      stub_singleton(store, :load) { loaded_data }

      config = Earl::Config.new
      manager = Earl::SessionManager.new(config: config, session_store: store)

      # Mock ClaudeSession to track creation
      started = []
      original_new = Earl::ClaudeSession.method(:new)
      stub_singleton(Earl::ClaudeSession, :new) do |**args|
        session = Object.new
        stub_singleton(session, :start) { started << args }
        stub_singleton(session, :alive?) { true }
        stub_singleton(session, :session_id) { args[:session_id] }
        stub_singleton(session, :kill) {}
        session
      end

      manager.resume_all

      assert_equal 1, started.size
      assert_equal "sess-123", started.first[:session_id]
      assert_equal :resume, started.first[:mode]
    ensure
      stub_singleton(Earl::ClaudeSession, :new) { |**args| original_new.call(**args) } if original_new
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
      stub_singleton(store, :load) { loaded_data }

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
      stub_singleton(store, :load) { loaded_data }
      stub_singleton(store, :save) { |*_args| }

      config = Earl::Config.new
      manager = Earl::SessionManager.new(config: config, session_store: store)

      # First, create a session that's dead
      original_new = Earl::ClaudeSession.method(:new)

      call_count = 0
      stub_singleton(Earl::ClaudeSession, :new) do |**args|
        call_count += 1
        session = Object.new
        stub_singleton(session, :start) {}
        stub_singleton(session, :alive?) { call_count > 1 } # first is dead, second is alive (resumed)
        stub_singleton(session, :session_id) { args[:session_id] || "new-session" }
        stub_singleton(session, :kill) {}
        mock_stats = Object.new
        stub_singleton(mock_stats, :total_cost) { 0.0 }
        stub_singleton(mock_stats, :total_input_tokens) { 0 }
        stub_singleton(mock_stats, :total_output_tokens) { 0 }
        stub_singleton(session, :stats) { mock_stats }
        session
      end

      sc = default_session_config

      # First get_or_create — creates a dead session
      manager.get_or_create("thread-abc12345", sc)

      # Second get_or_create — session is dead, should resume from store
      second = manager.get_or_create("thread-abc12345", sc)

      # The resumed session should have the original session_id
      assert_equal "sess-original", second.session_id
    ensure
      stub_singleton(Earl::ClaudeSession, :new) { |**args| original_new.call(**args) } if original_new
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
      stub_singleton(store, :load) { loaded_data }
      stub_singleton(store, :save) { |*_args| }

      config = Earl::Config.new
      manager = Earl::SessionManager.new(config: config, session_store: store)

      original_new = Earl::ClaudeSession.method(:new)
      call_count = 0
      stub_singleton(Earl::ClaudeSession, :new) do |**_args|
        call_count += 1
        session = Object.new
        if call_count == 1
          # Resume attempt fails
          stub_singleton(session, :start) { raise "resume failed" }
          stub_singleton(session, :alive?) { false }
          stub_singleton(session, :session_id) { "sess-broken" }
        else
          # Fallback to new session succeeds
          stub_singleton(session, :start) {}
          stub_singleton(session, :alive?) { true }
          stub_singleton(session, :session_id) { "sess-new" }
        end
        stub_singleton(session, :kill) {}
        mock_stats = Object.new
        stub_singleton(mock_stats, :total_cost) { 0.0 }
        stub_singleton(mock_stats, :total_input_tokens) { 0 }
        stub_singleton(mock_stats, :total_output_tokens) { 0 }
        stub_singleton(session, :stats) { mock_stats }
        session
      end

      result = manager.get_or_create("thread-abc12345", default_session_config)

      # Should have fallen back to a new session
      assert_equal "sess-new", result.session_id
    ensure
      stub_singleton(Earl::ClaudeSession, :new) { |**args| original_new.call(**args) } if original_new
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
      stub_singleton(store, :load) { loaded_data }

      config = Earl::Config.new
      manager = Earl::SessionManager.new(config: config, session_store: store)

      original_new = Earl::ClaudeSession.method(:new)
      stub_singleton(Earl::ClaudeSession, :new) do |**_args|
        session = Object.new
        stub_singleton(session, :start) { raise "connection refused" }
        session
      end

      # Should not raise
      assert_nothing_raised { manager.resume_all }

      # Session should not have been stored
      assert_nil manager.get("thread-abc12345")
    ensure
      stub_singleton(Earl::ClaudeSession, :new) { |**args| original_new.call(**args) } if original_new
    end

    test "stop_session calls remove on session_store when present" do
      removed = []
      mock_store = Object.new
      stub_singleton(mock_store, :remove) { |thread_id| removed << thread_id }
      stub_singleton(mock_store, :save) { |*_args| }
      stub_singleton(mock_store, :load) { {} }

      manager = Earl::SessionManager.new(session_store: mock_store)
      killed = false
      session = fake_session { killed = true }

      original_new = Earl::ClaudeSession.method(:new)
      stub_singleton(Earl::ClaudeSession, :new) { |**_args| session }
      manager.get_or_create("thread-abc12345", default_session_config)
      stub_singleton(Earl::ClaudeSession, :new) { |**args| original_new.call(**args) }

      manager.stop_session("thread-abc12345")

      assert killed
      assert_equal ["thread-abc12345"], removed
    end

    test "pause_all saves paused state to session_store" do
      saved = []
      mock_store = Object.new
      stub_singleton(mock_store, :save) do |thread_id, persisted|
        saved << { thread_id: thread_id, paused: persisted.is_paused }
      end
      stub_singleton(mock_store, :load) { {} }

      manager = Earl::SessionManager.new(session_store: mock_store)

      session = fake_session
      original_new = Earl::ClaudeSession.method(:new)
      stub_singleton(Earl::ClaudeSession, :new) { |**_args| session }
      manager.get_or_create("thread-abc12345", default_session_config)
      stub_singleton(Earl::ClaudeSession, :new) { |**args| original_new.call(**args) }

      saved.clear
      manager.pause_all

      assert_equal 1, saved.size
      assert_equal "thread-abc12345", saved.first[:thread_id]
      assert saved.first[:paused], "Expected session to be saved as paused"
    end

    test "build_permission_config returns McpConfig when config present" do
      ENV["EARL_SKIP_PERMISSIONS"] = nil
      ENV.delete("EARL_SKIP_PERMISSIONS")
      config = Earl::Config.new
      manager = Earl::SessionManager.new(config: config)

      result = manager.send(:build_permission_config, "thread-123", "channel-456")
      assert_instance_of Earl::ClaudeSession::McpConfig, result
      assert_not result.skip_permissions
      assert_equal "https://mattermost.example.com", result.env["PLATFORM_URL"]
      assert_equal "test-token", result.env["PLATFORM_TOKEN"]
      assert_equal "channel-456", result.env["PLATFORM_CHANNEL_ID"]
      assert_equal "thread-123", result.env["PLATFORM_THREAD_ID"]
      assert_equal "bot-123", result.env["PLATFORM_BOT_ID"]
    end

    test "build_permission_config merges PEARL_BIN env when set" do
      ENV["EARL_SKIP_PERMISSIONS"] = nil
      ENV.delete("EARL_SKIP_PERMISSIONS")
      ENV["PEARL_BIN"] = "/usr/local/bin/pearl"
      config = Earl::Config.new
      manager = Earl::SessionManager.new(config: config)

      result = manager.send(:build_permission_config, "thread-123", "channel-456")
      assert_instance_of Earl::ClaudeSession::McpConfig, result
      assert_equal "/usr/local/bin/pearl", result.env["PEARL_BIN"]
      assert_equal "https://mattermost.example.com", result.env["PLATFORM_URL"]
    ensure
      ENV.delete("PEARL_BIN")
    end

    test "claude_session_id_for returns active session id" do
      manager = Earl::SessionManager.new
      create_with_fake_session(manager, "thread-abc12345", alive: true)

      assert_equal "fake-session-id", manager.claude_session_id_for("thread-abc12345")
    end

    test "claude_session_id_for falls back to session store" do
      store = Object.new
      loaded_data = {
        "thread-abc12345" => Earl::SessionStore::PersistedSession.new(
          claude_session_id: "stored-sess-456",
          channel_id: "channel-1",
          working_dir: "/tmp",
          started_at: Time.now.iso8601,
          last_activity_at: Time.now.iso8601,
          is_paused: true,
          message_count: 5
        )
      }
      stub_singleton(store, :load) { loaded_data }

      manager = Earl::SessionManager.new(session_store: store)

      assert_equal "stored-sess-456", manager.claude_session_id_for("thread-abc12345")
    end

    test "claude_session_id_for returns nil for unknown thread" do
      manager = Earl::SessionManager.new
      assert_nil manager.claude_session_id_for("thread-unknown123")
    end

    test "persisted_session_for returns persisted data from store" do
      store = Object.new
      persisted = Earl::SessionStore::PersistedSession.new(
        claude_session_id: "sess-abc",
        total_cost: 1.23,
        total_input_tokens: 5000,
        total_output_tokens: 2000
      )
      stub_singleton(store, :load) { { "thread-abc12345" => persisted } }

      manager = Earl::SessionManager.new(session_store: store)
      result = manager.persisted_session_for("thread-abc12345")

      assert_equal "sess-abc", result.claude_session_id
      assert_equal 1.23, result.total_cost
      assert_equal 5000, result.total_input_tokens
    end

    test "persisted_session_for returns nil without session_store" do
      manager = Earl::SessionManager.new
      assert_nil manager.persisted_session_for("thread-abc12345")
    end

    test "save_stats updates persisted session with current stats" do
      saved = []
      store = Object.new
      persisted = Earl::SessionStore::PersistedSession.new(
        claude_session_id: "sess-abc",
        channel_id: "ch-1",
        total_cost: 0.0,
        total_input_tokens: 0,
        total_output_tokens: 0
      )
      stub_singleton(store, :load) { { "thread-abc12345" => persisted } }
      stub_singleton(store, :save) { |thread_id, p| saved << { thread_id: thread_id, persisted: p } }

      manager = Earl::SessionManager.new(session_store: store)

      # Create a session with stats
      session = fake_session
      mock_stats = Object.new
      stub_singleton(mock_stats, :total_cost) { 0.42 }
      stub_singleton(mock_stats, :total_input_tokens) { 8000 }
      stub_singleton(mock_stats, :total_output_tokens) { 3000 }
      stub_singleton(session, :stats) { mock_stats }

      original_new = Earl::ClaudeSession.method(:new)
      stub_singleton(Earl::ClaudeSession, :new) { |**_args| session }
      manager.get_or_create("thread-abc12345", default_session_config)
      stub_singleton(Earl::ClaudeSession, :new) { |**args| original_new.call(**args) }

      saved.clear
      manager.save_stats("thread-abc12345")

      assert_equal 1, saved.size
      assert_equal 0.42, saved.first[:persisted].total_cost
      assert_equal 8000, saved.first[:persisted].total_input_tokens
      assert_equal 3000, saved.first[:persisted].total_output_tokens
    end

    test "save_stats does nothing when session is nil" do
      store = Object.new
      saved = []
      stub_singleton(store, :load) { {} }
      stub_singleton(store, :save) { |tid, p| saved << { tid: tid, p: p } }

      manager = Earl::SessionManager.new(session_store: store)
      manager.save_stats("nonexistent-thread")

      assert_empty saved
    end

    test "save_stats does nothing when session_store is nil" do
      manager = Earl::SessionManager.new(session_store: nil)
      create_with_fake_session(manager, "thread-no-store")

      assert_nothing_raised { manager.save_stats("thread-no-store") }
    end

    test "save_stats does nothing when persisted session is nil" do
      saved_during_stats = []
      store = Object.new
      stub_singleton(store, :load) { {} }
      stub_singleton(store, :save) { |tid, p| saved_during_stats << { tid: tid, p: p } }

      manager = Earl::SessionManager.new(session_store: store)
      create_with_fake_session(manager, "thread-no-persist")

      saved_during_stats.clear
      manager.save_stats("thread-no-persist")

      assert_empty saved_during_stats
    end

    private

    def default_session_config
      Earl::SessionManager::SessionConfig.new(channel_id: nil, working_dir: nil, username: nil)
    end

    def create_with_fake_session(manager, thread_id, alive: true, &on_kill)
      session = fake_session(alive: alive, &on_kill)

      original_new = Earl::ClaudeSession.method(:new)
      stub_singleton(Earl::ClaudeSession, :new) { |**_args| session }

      manager.get_or_create(thread_id, default_session_config)
    ensure
      stub_singleton(Earl::ClaudeSession, :new) { |**args| original_new.call(**args) } if original_new
    end

    def fake_session(alive: true, &on_kill)
      session = Object.new
      stub_singleton(session, :start) {}
      stub_singleton(session, :alive?) { alive }
      stub_singleton(session, :kill) { on_kill&.call }
      stub_singleton(session, :session_id) { "fake-session-id" }
      mock_stats = Object.new
      stub_singleton(mock_stats, :total_cost) { 0.0 }
      stub_singleton(mock_stats, :total_input_tokens) { 0 }
      stub_singleton(mock_stats, :total_output_tokens) { 0 }
      stub_singleton(session, :stats) { mock_stats }
      session
    end
  end
end
