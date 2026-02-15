require "test_helper"

class Earl::SessionStoreTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)
    @tmp_dir = File.join(Dir.tmpdir, "earl-test-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@tmp_dir)
    @store_path = File.join(@tmp_dir, "sessions.json")
    @store = Earl::SessionStore.new(path: @store_path)
  end

  teardown do
    Earl.logger = nil
    FileUtils.rm_rf(@tmp_dir)
  end

  test "load returns empty hash when file does not exist" do
    assert_equal({}, @store.load)
  end

  test "save and load round-trips a session" do
    session = Earl::SessionStore::PersistedSession.new(
      claude_session_id: "sess-123",
      channel_id: "channel-1",
      working_dir: "/tmp/project",
      started_at: "2026-01-01T00:00:00Z",
      last_activity_at: "2026-01-01T00:01:00Z",
      is_paused: false,
      message_count: 5
    )

    @store.save("thread-abc", session)
    loaded = @store.load

    assert_equal 1, loaded.size
    assert_equal "sess-123", loaded["thread-abc"].claude_session_id
    assert_equal "channel-1", loaded["thread-abc"].channel_id
    assert_equal "/tmp/project", loaded["thread-abc"].working_dir
    assert_equal false, loaded["thread-abc"].is_paused
    assert_equal 5, loaded["thread-abc"].message_count
  end

  test "save multiple sessions" do
    s1 = build_session(id: "sess-1")
    s2 = build_session(id: "sess-2")

    @store.save("thread-1", s1)
    @store.save("thread-2", s2)

    loaded = @store.load
    assert_equal 2, loaded.size
    assert_equal "sess-1", loaded["thread-1"].claude_session_id
    assert_equal "sess-2", loaded["thread-2"].claude_session_id
  end

  test "remove deletes a session" do
    s1 = build_session(id: "sess-1")
    s2 = build_session(id: "sess-2")

    @store.save("thread-1", s1)
    @store.save("thread-2", s2)
    @store.remove("thread-1")

    loaded = @store.load
    assert_equal 1, loaded.size
    assert_nil loaded["thread-1"]
    assert_equal "sess-2", loaded["thread-2"].claude_session_id
  end

  test "remove handles non-existent thread" do
    assert_nothing_raised { @store.remove("thread-unknown") }
  end

  test "touch updates last_activity_at" do
    old_time = "2026-01-01T00:00:00Z"
    session = Earl::SessionStore::PersistedSession.new(
      claude_session_id: "sess-1",
      channel_id: "channel-1",
      working_dir: "/tmp",
      started_at: old_time,
      last_activity_at: old_time,
      is_paused: false,
      message_count: 0
    )
    @store.save("thread-1", session)

    @store.touch("thread-1")

    loaded = @store.load
    assert_not_equal old_time, loaded["thread-1"].last_activity_at
  end

  test "touch handles non-existent thread" do
    assert_nothing_raised { @store.touch("thread-unknown") }
  end

  test "load handles corrupted JSON" do
    File.write(@store_path, "not valid json{{{")
    assert_equal({}, @store.load)
  end

  test "save uses atomic write" do
    session = build_session(id: "sess-1")
    @store.save("thread-1", session)

    # Verify no temp files left behind
    tmp_files = Dir.glob(File.join(@tmp_dir, "sessions.json.tmp.*"))
    assert_empty tmp_files
  end

  test "save creates directory if needed" do
    nested_path = File.join(@tmp_dir, "nested", "dir", "sessions.json")
    store = Earl::SessionStore.new(path: nested_path)

    session = build_session(id: "sess-1")
    store.save("thread-1", session)

    assert File.exist?(nested_path)
  end

  test "write_store rescues errors and cleans up tmp file" do
    store_path = File.join(@tmp_dir, "readonly", "sessions.json")
    readonly_dir = File.join(@tmp_dir, "readonly")
    FileUtils.mkdir_p(readonly_dir)

    store = Earl::SessionStore.new(path: store_path)
    session = build_session(id: "sess-1")

    # First write works
    store.save("thread-1", session)

    # Now make the file un-renameable by removing write permission on directory
    File.chmod(0o444, readonly_dir)

    # This should rescue and not raise
    assert_nothing_raised { store.save("thread-2", build_session(id: "sess-2")) }
  ensure
    File.chmod(0o755, readonly_dir) if Dir.exist?(readonly_dir)
  end

  private

  def build_session(id: "sess-1")
    Earl::SessionStore::PersistedSession.new(
      claude_session_id: id,
      channel_id: "channel-1",
      working_dir: "/tmp",
      started_at: Time.now.iso8601,
      last_activity_at: Time.now.iso8601,
      is_paused: false,
      message_count: 0
    )
  end
end
