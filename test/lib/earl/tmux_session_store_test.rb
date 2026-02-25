# frozen_string_literal: true

require "test_helper"

module Earl
  class TmuxSessionStoreTest < Minitest::Test
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
          ["", success]
        else
          ["can't find session", failure]
        end
      end

      dead = @store.cleanup!
      assert_equal ["dead"], dead
      assert_equal "alive", @store.get("alive").name
      assert_nil @store.get("dead")
    end

    test "cleanup! returns empty array when all sessions alive" do
      @store.save(build_info(name: "alive"))

      success = mock_status(true)
      Open3.define_singleton_method(:capture2e) do |*_args|
        ["", success]
      end

      dead = @store.cleanup!
      assert_empty dead
    end

    test "handles corrupted JSON" do
      File.write(@store_path, "not valid json{{{")
      assert_equal({}, @store.all)
    end

    test "backs up corrupted JSON before overwriting" do
      File.write(@store_path, "not valid json{{{")
      @store.all # triggers read_store which backs up

      backups = Dir.glob("#{@store_path}.corrupt.*")
      assert_equal 1, backups.size
      assert_equal "not valid json{{{", File.read(backups.first)
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

    test "dirty flag retries write on next operation" do
      store_path = File.join(@tmp_dir, "readonly", "tmux_sessions.json")
      readonly_dir = File.join(@tmp_dir, "readonly")
      FileUtils.mkdir_p(readonly_dir)

      store = Earl::TmuxSessionStore.new(path: store_path)
      store.save(build_info(name: "session-1"))

      # Make write fail
      File.chmod(0o444, readonly_dir)
      store.save(build_info(name: "session-2"))

      # Verify dirty flag is set
      assert store.instance_variable_get(:@dirty)

      # Restore permissions — next operation should retry
      File.chmod(0o755, readonly_dir)
      store.save(build_info(name: "session-3"))

      # Dirty flag should be cleared after successful write
      assert_not store.instance_variable_get(:@dirty)

      # All sessions should be persisted
      new_store = Earl::TmuxSessionStore.new(path: store_path)
      assert_equal 3, new_store.all.size
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

    test "read_store handles Errno::ENOENT during read race" do
      # Simulate file disappearing between exist? check and File.read
      Earl::TmuxSessionStore.new(path: File.join(@tmp_dir, "vanishing.json"))

      # Write then delete — force the cache to be nil so read_store is called
      vanishing_path = File.join(@tmp_dir, "vanishing.json")
      File.write(vanishing_path, '{"a": {"name": "a"}}')
      vanishing_store = Earl::TmuxSessionStore.new(path: vanishing_path)

      # Delete the file to trigger ENOENT during read (race condition)
      File.delete(vanishing_path)
      vanishing_store.instance_variable_set(:@cache, nil) # force re-read

      result = vanishing_store.all
      assert_equal({}, result)
    end

    test "backup_corrupted_store is a no-op when file does not exist" do
      store = Earl::TmuxSessionStore.new(path: File.join(@tmp_dir, "nonexistent.json"))

      # Should not raise and should not create any backup files
      assert_nothing_raised { store.send(:backup_corrupted_store) }

      backups = Dir.glob(File.join(@tmp_dir, "nonexistent.json.corrupt.*"))
      assert_empty backups
    end

    test "cleanup! skips write when all sessions are alive (no dead)" do
      # All sessions alive — cleanup! returns empty and doesn't modify cache
      @store.save(build_info(name: "alive-1"))
      @store.save(build_info(name: "alive-2"))

      success = mock_status(true)
      Open3.define_singleton_method(:capture2e) { |*_args| ["", success] }

      dead = @store.cleanup!
      assert_empty dead
      assert_equal 2, @store.all.size
    end

    test "remove_dead_sessions handles nil cache gracefully" do
      # Set cache to nil, then call remove_dead_sessions
      @store.instance_variable_set(:@cache, nil)

      # Should not raise — &. operator protects against nil cache
      result = @store.send(:remove_dead_sessions, ["ghost"])
      assert_equal ["ghost"], result
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
end
