require "test_helper"

class Earl::RunnerTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)

    @original_env = ENV.to_h.slice(
      "MATTERMOST_URL", "MATTERMOST_BOT_TOKEN", "MATTERMOST_BOT_ID",
      "EARL_CHANNEL_ID", "EARL_ALLOWED_USERS"
    )

    ENV["MATTERMOST_URL"] = "https://mattermost.example.com"
    ENV["MATTERMOST_BOT_TOKEN"] = "test-token"
    ENV["MATTERMOST_BOT_ID"] = "bot-123"
    ENV["EARL_CHANNEL_ID"] = "channel-456"
    ENV["EARL_ALLOWED_USERS"] = "alice,bob"
  end

  teardown do
    Earl.logger = nil
    %w[MATTERMOST_URL MATTERMOST_BOT_TOKEN MATTERMOST_BOT_ID EARL_CHANNEL_ID EARL_ALLOWED_USERS].each do |key|
      if @original_env.key?(key)
        ENV[key] = @original_env[key]
      else
        ENV.delete(key)
      end
    end
  end

  test "allowed_user? returns true for allowed users" do
    runner = Earl::Runner.new
    assert runner.send(:allowed_user?, "alice")
    assert runner.send(:allowed_user?, "bob")
  end

  test "allowed_user? returns false for non-allowed users" do
    runner = Earl::Runner.new
    assert_not runner.send(:allowed_user?, "eve")
  end

  test "allowed_user? returns true for everyone when list is empty" do
    ENV["EARL_ALLOWED_USERS"] = ""
    runner = Earl::Runner.new
    assert runner.send(:allowed_user?, "anyone")
  end

  test "stop_typing kills the thread" do
    runner = Earl::Runner.new
    thread = Thread.new { sleep 60 }

    runner.send(:stop_typing, thread)
    sleep 0.05

    assert_not thread.alive?
  end

  test "stop_typing handles nil thread" do
    runner = Earl::Runner.new
    assert_nothing_raised { runner.send(:stop_typing, nil) }
  end

  test "handle_message sends text to session" do
    runner = Earl::Runner.new

    sent_text = nil
    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&_block| }
    mock_session.define_singleton_method(:on_complete) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |text| sent_text = text }

    mock_manager = Object.new
    mock_manager.define_singleton_method(:get_or_create) { |_thread_id| mock_session }
    runner.instance_variable_set(:@session_manager, mock_manager)

    # Stub typing to avoid real HTTP calls
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }

    runner.send(:handle_message, sender_name: "alice", thread_id: "thread-12345678", text: "Hello Earl")
    sleep 0.05

    assert_equal "Hello Earl", sent_text
  end

  test "on_text callback creates post on first chunk then updates on subsequent" do
    runner = Earl::Runner.new

    on_text_callback = nil
    on_complete_callback = nil

    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
    mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
    mock_session.define_singleton_method(:send_message) { |_text| }
    mock_session.define_singleton_method(:total_cost) { 0.05 }

    mock_manager = Object.new
    mock_manager.define_singleton_method(:get_or_create) { |_thread_id| mock_session }
    runner.instance_variable_set(:@session_manager, mock_manager)

    created_posts = []
    updated_posts = []
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      created_posts << { channel_id: channel_id, message: message, root_id: root_id }
      { "id" => "reply-post-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    runner.send(:handle_message, sender_name: "alice", thread_id: "thread-12345678", text: "test")
    sleep 0.05

    # First chunk creates a post
    on_text_callback.call("Hello from Claude")

    assert_equal 1, created_posts.size
    assert_equal "Hello from Claude", created_posts.first[:message]
    assert_equal "thread-12345678", created_posts.first[:root_id]

    # Subsequent chunk after debounce updates
    sleep 0.35
    on_text_callback.call("Hello from Claude, updated")

    assert_equal 1, updated_posts.size
    assert_equal "reply-post-1", updated_posts.first[:post_id]

    # on_complete does final update
    on_complete_callback.call(mock_session)

    final = updated_posts.last
    assert_equal "Hello from Claude, updated", final[:message]
  end

  test "setup_message_handler registers callback with mattermost" do
    runner = Earl::Runner.new
    mm = runner.instance_variable_get(:@mattermost)

    # Verify on_message was called during setup (callback is stored)
    runner.send(:setup_message_handler)

    # The callback exists (on_message was called with a block)
    assert_not_nil mm.instance_variable_get(:@on_message)
  end

  test "start_typing creates a thread" do
    runner = Earl::Runner.new

    # Stub send_typing to not make real HTTP calls
    mm = runner.instance_variable_get(:@mattermost)
    typing_calls = []
    mm.define_singleton_method(:send_typing) { |**args| typing_calls << args }

    thread = runner.send(:start_typing, "thread-123")

    sleep 0.1
    assert thread.alive?
    assert typing_calls.any?

    runner.send(:stop_typing, thread)
    sleep 0.1
    assert_not thread.alive?
  end

  test "setup_signal_handlers can be called without error" do
    runner = Earl::Runner.new
    assert_nothing_raised { runner.send(:setup_signal_handlers) }
  end

  test "debounce timer fires when time has not elapsed" do
    runner = Earl::Runner.new

    on_text_callback = nil
    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
    mock_session.define_singleton_method(:on_complete) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |_text| }

    mock_manager = Object.new
    mock_manager.define_singleton_method(:get_or_create) { |_thread_id| mock_session }
    runner.instance_variable_set(:@session_manager, mock_manager)

    updated_posts = []
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    runner.send(:handle_message, sender_name: "alice", thread_id: "thread-12345678", text: "test")
    sleep 0.05

    # First chunk creates post
    on_text_callback.call("Part 1")

    # Rapid second chunk (within debounce window) — should schedule timer
    on_text_callback.call("Part 1 Part 2")

    # Wait for debounce timer to fire
    sleep 0.5

    assert updated_posts.any? { |u| u[:message] == "Part 1 Part 2" }
  end

  test "start method calls setup methods and enters main loop" do
    runner = Earl::Runner.new
    mm = runner.instance_variable_get(:@mattermost)

    # Stub connect to not make real WebSocket calls
    mm.define_singleton_method(:connect) { }

    # Set shutting_down so the loop exits immediately
    runner.instance_variable_set(:@shutting_down, true)

    assert_nothing_raised { runner.start }
  end

  test "start_typing rescues errors in typing loop" do
    runner = Earl::Runner.new
    mm = runner.instance_variable_get(:@mattermost)

    # Make send_typing raise an error
    mm.define_singleton_method(:send_typing) { |**_args| raise "connection lost" }

    thread = runner.send(:start_typing, "thread-123")
    sleep 0.1

    # Thread should have exited due to the rescue/break
    assert_not thread.alive?
  end

  test "on_complete without prior text does not update post" do
    runner = Earl::Runner.new

    on_text_callback = nil
    on_complete_callback = nil

    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
    mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
    mock_session.define_singleton_method(:send_message) { |_text| }
    mock_session.define_singleton_method(:total_cost) { 0.0 }

    mock_manager = Object.new
    mock_manager.define_singleton_method(:get_or_create) { |_thread_id| mock_session }
    runner.instance_variable_set(:@session_manager, mock_manager)

    updated_posts = []
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    runner.send(:handle_message, sender_name: "alice", thread_id: "thread-12345678", text: "test")
    sleep 0.05

    # Fire on_complete without any text received — no reply_post_id exists
    on_complete_callback.call(mock_session)

    assert_empty updated_posts
  end

  test "debounce timer already scheduled does not create another" do
    runner = Earl::Runner.new

    on_text_callback = nil
    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
    mock_session.define_singleton_method(:on_complete) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |_text| }

    mock_manager = Object.new
    mock_manager.define_singleton_method(:get_or_create) { |_thread_id| mock_session }
    runner.instance_variable_set(:@session_manager, mock_manager)

    update_count = 0
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      update_count += 1
    end

    runner.send(:handle_message, sender_name: "alice", thread_id: "thread-12345678", text: "test")
    sleep 0.05

    # First chunk creates post
    on_text_callback.call("Part 1")

    # Rapid second chunk — schedules debounce timer
    on_text_callback.call("Part 1 Part 2")

    # Rapid third chunk — timer already scheduled, should NOT create another
    on_text_callback.call("Part 1 Part 2 Part 3")

    # Wait for single debounce timer to fire
    sleep 0.5

    # Only one debounced update should have fired
    assert_equal 1, update_count
  end

  test "start enters main loop before exiting" do
    runner = Earl::Runner.new
    mm = runner.instance_variable_get(:@mattermost)
    mm.define_singleton_method(:connect) { }

    # Set shutting_down after a brief delay so the loop runs at least once
    Thread.new do
      sleep 0.1
      runner.instance_variable_set(:@shutting_down, true)
    end

    assert_nothing_raised { runner.start }
  end

  test "message handler calls handle_message for allowed users" do
    runner = Earl::Runner.new

    mm = runner.instance_variable_get(:@mattermost)
    runner.send(:setup_message_handler)
    callback = mm.instance_variable_get(:@on_message)

    sent_text = nil
    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&_block| }
    mock_session.define_singleton_method(:on_complete) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |text| sent_text = text }

    mock_manager = Object.new
    mock_manager.define_singleton_method(:get_or_create) { |_thread_id| mock_session }
    runner.instance_variable_set(:@session_manager, mock_manager)
    mm.define_singleton_method(:send_typing) { |**_args| }

    callback.call(sender_name: "alice", thread_id: "thread-12345678", text: "Hi Earl", post_id: "post-1")
    sleep 0.05

    assert_equal "Hi Earl", sent_text
  end

  test "message handler ignores non-allowed users" do
    runner = Earl::Runner.new

    mm = runner.instance_variable_get(:@mattermost)
    runner.send(:setup_message_handler)

    # Get the callback that was registered
    callback = mm.instance_variable_get(:@on_message)

    # Mock the session_manager to ensure it's never called for non-allowed user
    session_created = false
    mock_manager = Object.new
    mock_manager.define_singleton_method(:get_or_create) { |_id| session_created = true }
    runner.instance_variable_set(:@session_manager, mock_manager)

    callback.call(sender_name: "eve", thread_id: "thread-1", text: "Hi", post_id: "post-1")

    assert_not session_created
  end
end
