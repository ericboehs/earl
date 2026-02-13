require "test_helper"

class Earl::RunnerTest < ActiveSupport::TestCase
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
    ENV["EARL_ALLOWED_USERS"] = "alice,bob"
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

  test "process_message sends text to session" do
    runner = Earl::Runner.new

    sent_text = nil
    mock_session = build_mock_session(on_send: ->(text) { sent_text = text })
    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    # Stub typing to avoid real HTTP calls
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }

    runner.send(:process_message, thread_id: "thread-12345678", text: "Hello Earl")
    sleep 0.05

    assert_equal "Hello Earl", sent_text
  end

  test "on_text callback creates post on first chunk then updates on subsequent" do
    runner = Earl::Runner.new

    on_text_callback = nil
    on_complete_callback = nil
    stats = mock_stats

    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
    mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
    mock_session.define_singleton_method(:on_tool_use) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |_text| }
    mock_session.define_singleton_method(:total_cost) { 0.05 }
    mock_session.define_singleton_method(:stats) { stats }

    mock_manager = build_mock_manager(mock_session)
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

    runner.send(:process_message, thread_id: "thread-12345678", text: "test")
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

  test "debounce timer fires when time has not elapsed" do
    runner = Earl::Runner.new

    on_text_callback = nil
    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
    mock_session.define_singleton_method(:on_complete) { |&_block| }
    mock_session.define_singleton_method(:on_tool_use) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |_text| }

    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    updated_posts = []
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    runner.send(:process_message, thread_id: "thread-12345678", text: "test")
    sleep 0.05

    # First chunk creates post
    on_text_callback.call("Part 1")

    # Rapid second chunk (within debounce window) — should schedule timer
    on_text_callback.call("Part 1 Part 2")

    # Wait for debounce timer to fire
    sleep 0.5

    assert updated_posts.any? { |u| u[:message] == "Part 1 Part 2" }
  end

  test "setup_signal_handlers can be called without error" do
    runner = Earl::Runner.new
    assert_nothing_raised { runner.send(:setup_signal_handlers) }
  end

  test "start method calls setup methods and enters main loop" do
    runner = Earl::Runner.new
    mm = runner.instance_variable_get(:@mattermost)

    # Stub connect to not make real WebSocket calls
    mm.define_singleton_method(:connect) { }

    # Set shutting_down so the loop exits immediately
    runner.instance_variable_get(:@app_state).shutting_down = true

    # Kill the idle checker thread after start
    assert_nothing_raised { runner.start }
  ensure
    runner.instance_variable_get(:@idle_checker_thread)&.kill
  end

  test "on_complete without prior text does not update post" do
    runner = Earl::Runner.new

    on_text_callback = nil
    on_complete_callback = nil
    stats = mock_stats

    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
    mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
    mock_session.define_singleton_method(:on_tool_use) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |_text| }
    mock_session.define_singleton_method(:total_cost) { 0.0 }
    mock_session.define_singleton_method(:stats) { stats }

    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    updated_posts = []
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    runner.send(:process_message, thread_id: "thread-12345678", text: "test")
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
    mock_session.define_singleton_method(:on_tool_use) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |_text| }

    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    update_count = 0
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      update_count += 1
    end

    runner.send(:process_message, thread_id: "thread-12345678", text: "test")
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
      runner.instance_variable_get(:@app_state).shutting_down = true
    end

    assert_nothing_raised { runner.start }
  ensure
    runner.instance_variable_get(:@idle_checker_thread)&.kill
  end

  test "message handler calls enqueue_message for allowed users" do
    runner = Earl::Runner.new

    mm = runner.instance_variable_get(:@mattermost)
    runner.send(:setup_message_handler)
    callback = mm.instance_variable_get(:@on_message)

    sent_text = nil
    mock_session = build_mock_session(on_send: ->(text) { sent_text = text })
    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)
    mm.define_singleton_method(:send_typing) { |**_args| }

    callback.call(sender_name: "alice", thread_id: "thread-12345678", text: "Hi Earl", post_id: "post-1", channel_id: "channel-456")
    sleep 0.05

    assert_equal "Hi Earl", sent_text
  end

  test "enqueue_message queues messages when thread is busy" do
    runner = Earl::Runner.new

    on_complete_callback = nil
    sent_messages = []
    stats = mock_stats
    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&_block| }
    mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
    mock_session.define_singleton_method(:on_tool_use) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |text| sent_messages << text }
    mock_session.define_singleton_method(:total_cost) { 0.0 }
    mock_session.define_singleton_method(:stats) { stats }

    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }

    # First message starts processing
    runner.send(:enqueue_message, thread_id: "thread-12345678", text: "first")
    sleep 0.05

    # Second message should be queued (thread is busy)
    runner.send(:enqueue_message, thread_id: "thread-12345678", text: "second")

    assert_equal [ "first" ], sent_messages

    # Complete first message — should process queued "second"
    on_complete_callback.call(mock_session)
    sleep 0.05

    assert_equal [ "first", "second" ], sent_messages
  end

  test "enqueue_message processes immediately for new thread" do
    runner = Earl::Runner.new

    sent_text = nil
    mock_session = build_mock_session(on_send: ->(text) { sent_text = text })
    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }

    runner.send(:enqueue_message, thread_id: "thread-12345678", text: "hello")
    sleep 0.05

    assert_equal "hello", sent_text
  end

  test "on_complete drains queue and releases thread when empty" do
    runner = Earl::Runner.new

    on_complete_callback = nil
    stats = mock_stats
    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&_block| }
    mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
    mock_session.define_singleton_method(:on_tool_use) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |_text| }
    mock_session.define_singleton_method(:total_cost) { 0.0 }
    mock_session.define_singleton_method(:stats) { stats }

    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }

    runner.send(:enqueue_message, thread_id: "thread-12345678", text: "hello")
    sleep 0.05

    # Complete — no queued messages, should remove from processing_threads
    on_complete_callback.call(mock_session)

    message_queue = runner.instance_variable_get(:@app_state).message_queue
    processing = message_queue.instance_variable_get(:@processing_threads)
    assert_not processing.include?("thread-12345678")
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
    mock_manager.define_singleton_method(:get_or_create) { |*_args, **_kwargs| session_created = true }
    mock_manager.define_singleton_method(:touch) { |_id| }
    runner.instance_variable_set(:@session_manager, mock_manager)

    callback.call(sender_name: "eve", thread_id: "thread-1", text: "Hi", post_id: "post-1", channel_id: "channel-456")

    assert_not session_created
  end

  test "handle_incoming_message routes commands to executor" do
    runner = Earl::Runner.new

    executed_command = nil
    executor = runner.instance_variable_get(:@command_executor)
    executor.define_singleton_method(:execute) do |command, thread_id:, channel_id:|
      executed_command = command
    end

    runner.send(:handle_incoming_message, thread_id: "thread-12345678", text: "!help", channel_id: "channel-456")

    assert_not_nil executed_command
    assert_equal :help, executed_command.name
  end

  test "handle_incoming_message routes normal messages to enqueue" do
    runner = Earl::Runner.new

    sent_text = nil
    mock_session = build_mock_session(on_send: ->(text) { sent_text = text })
    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }

    runner.send(:handle_incoming_message, thread_id: "thread-12345678", text: "hello", channel_id: "channel-456")
    sleep 0.05

    assert_equal "hello", sent_text
  end

  test "setup_reaction_handler registers callback with mattermost" do
    runner = Earl::Runner.new
    mm = runner.instance_variable_get(:@mattermost)

    runner.send(:setup_reaction_handler)
    assert_not_nil mm.instance_variable_get(:@on_reaction)
  end

  test "on_tool_use callback delegates to question_handler" do
    runner = Earl::Runner.new

    on_tool_use_callback = nil
    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&_block| }
    mock_session.define_singleton_method(:on_complete) { |&_block| }
    mock_session.define_singleton_method(:on_tool_use) { |&block| on_tool_use_callback = block }
    mock_session.define_singleton_method(:send_message) { |_text| }

    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }

    runner.send(:process_message, thread_id: "thread-12345678", text: "test")
    sleep 0.05

    # Fire on_tool_use with a non-AskUserQuestion tool — should not error
    assert_nothing_raised { on_tool_use_callback.call({ id: "tu-1", name: "Bash", input: {} }) }
  end

  test "handle_reaction does nothing when question handler returns nil" do
    runner = Earl::Runner.new

    # No pending questions, so reaction handling returns nil
    assert_nothing_raised do
      runner.send(:handle_reaction, post_id: "unknown-post", emoji_name: "one")
    end
  end

  test "find_thread_for_question returns nil" do
    runner = Earl::Runner.new
    assert_nil runner.send(:find_thread_for_question, "tu-1")
  end

  test "resolve_working_dir uses command executor override first" do
    runner = Earl::Runner.new
    executor = runner.instance_variable_get(:@command_executor)

    # Set a working dir via the executor
    executor.instance_variable_get(:@working_dirs)["thread-1"] = "/custom/path"

    result = runner.send(:resolve_working_dir, "thread-1", "channel-456")
    assert_equal "/custom/path", result
  end

  test "resolve_working_dir falls back to channel config" do
    ENV["EARL_CHANNELS"] = "channel-456:/channel/path"
    runner = Earl::Runner.new

    result = runner.send(:resolve_working_dir, "thread-1", "channel-456")
    assert_equal "/channel/path", result
  end

  private

  def build_mock_session(on_send: nil)
    mock = Object.new
    mock.define_singleton_method(:on_text) { |&_block| }
    mock.define_singleton_method(:on_complete) { |&_block| }
    mock.define_singleton_method(:on_tool_use) { |&_block| }
    mock.define_singleton_method(:send_message) { |text| on_send&.call(text) }
    mock.define_singleton_method(:total_cost) { 0.0 }
    mock.define_singleton_method(:stats) do
      Earl::ClaudeSession::Stats.new(
        total_cost: 0.0, total_input_tokens: 0, total_output_tokens: 0,
        turn_input_tokens: 0, turn_output_tokens: 0,
        cache_read_tokens: 0, cache_creation_tokens: 0
      )
    end
    mock
  end

  def build_mock_manager(mock_session)
    mock = Object.new
    mock.define_singleton_method(:get_or_create) { |*_args, **_kwargs| mock_session }
    mock.define_singleton_method(:get) { |_id| mock_session }
    mock.define_singleton_method(:touch) { |_id| }
    mock
  end

  def mock_stats
    Earl::ClaudeSession::Stats.new(
      total_cost: 0.0, total_input_tokens: 0, total_output_tokens: 0,
      turn_input_tokens: 0, turn_output_tokens: 0,
      cache_read_tokens: 0, cache_creation_tokens: 0
    )
  end
end
