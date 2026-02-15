# frozen_string_literal: true

require "test_helper"

class Earl::TmuxSessionStoreTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)
    @tmp_dir = File.join(Dir.tmpdir, "earl-tmux-test-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@tmp_dir)
    @store_path = File.join(@tmp_dir, "tmux_sessions.json")
    @store = Earl::TmuxSessionStore.new(path: @store_path)
    @original_capture2e = Open3.method(:capture2e)
  end

  teardown do
    Earl.logger = nil
    FileUtils.rm_rf(@tmp_dir)
    restore_open3
  end

  test "all returns empty hash when file does not exist" do
    assert_equal({}, @store.all)
  end

  test "save and get round-trips session info" do
    info = build_info(name: "test-session")
    @store.save(info)

    loaded = @store.get("test-session")
    assert_equal "test-session", loaded.name
    assert_equal "channel-1", loaded.channel_id
    assert_equal "thread-1", loaded.thread_id
    assert_equal "/tmp/project", loaded.working_dir
    assert_equal "hello world", loaded.prompt
  end

  test "save multiple sessions" do
    @store.save(build_info(name: "session-1"))
    @store.save(build_info(name: "session-2"))

    all = @store.all
    assert_equal 2, all.size
    assert_equal "session-1", all["session-1"].name
    assert_equal "session-2", all["session-2"].name
  end

  test "get returns nil for non-existent session" do
    assert_nil @store.get("nonexistent")
  end

  test "delete removes a session" do
    @store.save(build_info(name: "session-1"))
    @store.save(build_info(name: "session-2"))
    @store.delete("session-1")

    assert_nil @store.get("session-1")
    assert_equal "session-2", @store.get("session-2").name
  end

  test "delete handles non-existent session" do
    assert_nothing_raised { @store.delete("nonexistent") }
  end

  test "all returns duplicate hash, not mutable reference" do
    @store.save(build_info(name: "session-1"))
    all = @store.all
    all.delete("session-1")

    # Original store should still have the session
    assert_equal "session-1", @store.get("session-1").name
  end

  test "cleanup! removes dead sessions" do
    @store.save(build_info(name: "alive"))
    @store.save(build_info(name: "dead"))

    # Pre-create status objects so they're captured in the closure
    success = mock_status(true)
    failure = mock_status(false)

    Open3.define_singleton_method(:capture2e) do |*args|
      if args.include?("alive")
        [ "", success ]
      else
        [ "can't find session", failure ]
      end
    end

    dead = @store.cleanup!
    assert_equal [ "dead" ], dead
    assert_equal "alive", @store.get("alive").name
    assert_nil @store.get("dead")
  end

  test "cleanup! returns empty array when all sessions alive" do
    @store.save(build_info(name: "alive"))

    success = mock_status(true)
    Open3.define_singleton_method(:capture2e) do |*_args|
      [ "", success ]
    end

    dead = @store.cleanup!
    assert_empty dead
  end

  test "handles corrupted JSON" do
    File.write(@store_path, "not valid json{{{")
    assert_equal({}, @store.all)
  end

  test "handles unknown keys in JSON gracefully" do
    json_with_extra_keys = {
      "my-session" => {
        "name" => "my-session",
        "channel_id" => "ch-1",
        "thread_id" => "th-1",
        "working_dir" => "/tmp",
        "prompt" => "hello",
        "created_at" => "2026-02-15T00:00:00-06:00",
        "unknown_field" => "should be ignored",
        "another_extra" => 42
      }
    }
    File.write(@store_path, JSON.pretty_generate(json_with_extra_keys))

    store = Earl::TmuxSessionStore.new(path: @store_path)
    session = store.get("my-session")
    assert_equal "my-session", session.name
    assert_equal "ch-1", session.channel_id
    assert_equal "hello", session.prompt
  end

  test "save uses atomic write" do
    @store.save(build_info(name: "session-1"))

    tmp_files = Dir.glob(File.join(@tmp_dir, "tmux_sessions.json.tmp.*"))
    assert_empty tmp_files
  end

  test "save creates directory if needed" do
    nested_path = File.join(@tmp_dir, "nested", "dir", "tmux_sessions.json")
    store = Earl::TmuxSessionStore.new(path: nested_path)

    store.save(build_info(name: "session-1"))
    assert File.exist?(nested_path)
  end

  test "persists across new store instances" do
    @store.save(build_info(name: "session-1"))

    new_store = Earl::TmuxSessionStore.new(path: @store_path)
    assert_equal "session-1", new_store.get("session-1").name
  end

  test "write_store rescues errors and cleans up tmp file" do
    store_path = File.join(@tmp_dir, "readonly", "tmux_sessions.json")
    readonly_dir = File.join(@tmp_dir, "readonly")
    FileUtils.mkdir_p(readonly_dir)

    store = Earl::TmuxSessionStore.new(path: store_path)
    info = build_info(name: "session-1")

    # First write works
    store.save(info)

    # Now make the file un-renameable by removing write permission on directory
    File.chmod(0o444, readonly_dir)

    # This should rescue and not raise
    assert_nothing_raised { store.save(build_info(name: "session-2")) }
  ensure
    File.chmod(0o755, readonly_dir) if Dir.exist?(readonly_dir)
  end

  test "read_store handles missing struct members gracefully" do
    json_with_partial_keys = {
      "partial-session" => {
        "name" => "partial-session"
      }
    }
    File.write(@store_path, JSON.pretty_generate(json_with_partial_keys))

    store = Earl::TmuxSessionStore.new(path: @store_path)
    session = store.get("partial-session")
    assert_equal "partial-session", session.name
    assert_nil session.channel_id
  end

  private

  def build_info(name: "test-session")
    Earl::TmuxSessionStore::TmuxSessionInfo.new(
      name: name,
      channel_id: "channel-1",
      thread_id: "thread-1",
      working_dir: "/tmp/project",
      prompt: "hello world",
      created_at: Time.now.iso8601
    )
  end

  def mock_status(success)
    status = Object.new
    status.define_singleton_method(:success?) { success }
    status
  end

  def restore_open3
    original = @original_capture2e
    Open3.define_singleton_method(:capture2e) { |*args| original.call(*args) }
  end
end
