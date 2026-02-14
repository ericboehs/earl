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
    stats = mock_stats(total_input_tokens: 1000, total_output_tokens: 500)

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

    # Subsequent chunk after debounce updates with accumulated text
    sleep 0.35
    on_text_callback.call("updated")

    assert_equal 1, updated_posts.size
    assert_equal "reply-post-1", updated_posts.first[:post_id]

    # on_complete edits existing post with stats footer (text-only response)
    on_complete_callback.call(mock_session)

    # Text-only response: stats appended to existing post via update
    final_update = updated_posts.last
    assert_includes final_update[:message], "updated"
    assert_includes final_update[:message], "tokens"
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
    on_text_callback.call("Part 2")

    # Wait for debounce timer to fire
    sleep 0.5

    assert updated_posts.any? { |u| u[:message] == "Part 1\n\nPart 2" }
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

  test "on_complete without prior text does not update or create posts" do
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
    created_posts = []
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      created_posts << { channel_id: channel_id, message: message, root_id: root_id }
      { "id" => "notif-1" }
    end

    runner.send(:process_message, thread_id: "thread-12345678", text: "test")
    sleep 0.05

    # Fire on_complete without any text received — no reply_post_id exists
    on_complete_callback.call(mock_session)

    assert_empty updated_posts
    assert_empty created_posts
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
    on_text_callback.call("Part 2")

    # Rapid third chunk — timer already scheduled, should NOT create another
    on_text_callback.call("Part 3")

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
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "notif-1" } }

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
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "notif-1" } }

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

  test "on_tool_use routes to both response and question handler" do
    runner = Earl::Runner.new

    on_tool_use_callback = nil
    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&_block| }
    mock_session.define_singleton_method(:on_complete) { |&_block| }
    mock_session.define_singleton_method(:on_tool_use) { |&block| on_tool_use_callback = block }
    mock_session.define_singleton_method(:send_message) { |_text| }

    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    created_posts = []
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      created_posts << { message: message }
      { "id" => "reply-1" }
    end

    question_handler_called = false
    handler = runner.instance_variable_get(:@question_handler)
    handler.define_singleton_method(:handle_tool_use) { |**_args| question_handler_called = true; nil }

    runner.send(:process_message, thread_id: "thread-12345678", text: "test")
    sleep 0.05

    on_tool_use_callback.call({ id: "tu-1", name: "Bash", input: { "command" => "echo hi" } })

    # StreamingResponse should have created a post with tool indicator
    assert created_posts.any? { |p| p[:message].include?("🔧 `Bash`") },
           "Expected tool indicator in post, got: #{created_posts.inspect}"

    # QuestionHandler should also have been called
    assert question_handler_called, "Expected question_handler.handle_tool_use to be called"
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

  test "final post includes token count and context percent" do
    runner = Earl::Runner.new

    on_text_callback = nil
    on_complete_callback = nil
    stats = mock_stats(total_input_tokens: 5000, total_output_tokens: 1500, context_window: 200_000,
                        turn_input_tokens: 5000, cache_read_tokens: 30_000)

    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
    mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
    mock_session.define_singleton_method(:on_tool_use) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |_text| }
    mock_session.define_singleton_method(:stats) { stats }

    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    updated_posts = []
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      { "id" => "post-1" }
    end

    runner.send(:process_message, thread_id: "thread-12345678", text: "test")
    sleep 0.05

    on_text_callback.call("Here is the answer.")
    on_complete_callback.call(mock_session)

    # Text-only response: edits existing post with stats footer
    final_update = updated_posts.last
    assert_includes final_update[:message], "Here is the answer."
    assert_includes final_update[:message], "6,500 tokens"
    assert_includes final_update[:message], "% context"
  end

  test "final post has no stats footer when no tokens" do
    runner = Earl::Runner.new

    on_text_callback = nil
    on_complete_callback = nil
    stats = mock_stats

    mock_session = Object.new
    mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
    mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
    mock_session.define_singleton_method(:on_tool_use) { |&_block| }
    mock_session.define_singleton_method(:send_message) { |_text| }
    mock_session.define_singleton_method(:stats) { stats }

    mock_manager = build_mock_manager(mock_session)
    runner.instance_variable_set(:@session_manager, mock_manager)

    updated_posts = []
    mock_mm = runner.instance_variable_get(:@mattermost)
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      { "id" => "post-1" }
    end

    runner.send(:process_message, thread_id: "thread-12345678", text: "test")
    sleep 0.05

    on_text_callback.call("Simple reply")
    on_complete_callback.call(mock_session)

    # Text-only response with no tokens: edits post, no stats footer
    final_update = updated_posts.last
    assert_equal "Simple reply", final_update[:message]
    assert_not_includes final_update[:message], "tokens"
  end

  test "format_number formats numbers with commas" do
    runner = Earl::Runner.new
    assert_equal "1,234", runner.send(:format_number, 1234)
    assert_equal "12,345,678", runner.send(:format_number, 12_345_678)
    assert_equal "500", runner.send(:format_number, 500)
    assert_equal "0", runner.send(:format_number, nil)
  end

  test "configure_channels uses multi-channel when multiple channels configured" do
    ENV["EARL_CHANNELS"] = "chan1:/path1,chan2:/path2"
    runner = Earl::Runner.new
    mm = runner.instance_variable_get(:@mattermost)
    channel_ids = mm.instance_variable_get(:@channel_ids)
    assert channel_ids.size > 1
  end

  test "handle_shutdown_signal is idempotent" do
    runner = Earl::Runner.new
    app_state = runner.instance_variable_get(:@app_state)

    # First call should set shutting_down
    # Stub Thread.new to avoid actually spawning shutdown thread
    threads_spawned = 0
    original_new = Thread.method(:new)
    Thread.define_singleton_method(:new) do |&block|
      threads_spawned += 1
      original_new.call { } # no-op thread
    end

    runner.send(:handle_shutdown_signal)
    assert app_state.shutting_down
    assert_equal 1, threads_spawned

    # Second call should return early
    runner.send(:handle_shutdown_signal)
    assert_equal 1, threads_spawned # no additional thread
  ensure
    Thread.define_singleton_method(:new) { |&block| original_new.call(&block) } if original_new
  end

  test "handle_incoming_message ignores unparseable commands" do
    runner = Earl::Runner.new

    executed = false
    executor = runner.instance_variable_get(:@command_executor)
    executor.define_singleton_method(:execute) { |*_args, **_kwargs| executed = true }

    # "!unknown_thing" is command-like but CommandParser.parse returns nil
    runner.send(:handle_incoming_message, thread_id: "thread-12345678", text: "!unknown_thing",
                                          channel_id: "channel-456")

    assert_not executed
  end

  test "handle_reaction returns early when question handler returns nil result" do
    runner = Earl::Runner.new
    handler = runner.instance_variable_get(:@question_handler)
    handler.define_singleton_method(:handle_reaction) { |**_args| nil }

    assert_nothing_raised do
      runner.send(:handle_reaction, post_id: "post-1", emoji_name: "one")
    end
  end

  test "handle_reaction returns early when find_thread returns nil" do
    runner = Earl::Runner.new
    handler = runner.instance_variable_get(:@question_handler)
    handler.define_singleton_method(:handle_reaction) { |**_args| { tool_use_id: "tu-1", answer_text: "yes" } }

    # find_thread_for_question always returns nil currently
    assert_nothing_raised do
      runner.send(:handle_reaction, post_id: "post-1", emoji_name: "one")
    end
  end

  test "pause_if_idle skips paused sessions" do
    runner = Earl::Runner.new
    persisted = Earl::SessionStore::PersistedSession.new(
      is_paused: true,
      last_activity_at: (Time.now - 7200).iso8601
    )

    stopped = false
    manager = runner.instance_variable_get(:@session_manager)
    manager.define_singleton_method(:stop_session) { |_id| stopped = true }

    runner.send(:pause_if_idle, "thread-12345678", persisted)
    assert_not stopped
  end

  test "pause_if_idle skips recently active sessions" do
    runner = Earl::Runner.new
    persisted = Earl::SessionStore::PersistedSession.new(
      is_paused: false,
      last_activity_at: Time.now.iso8601
    )

    stopped = false
    manager = runner.instance_variable_get(:@session_manager)
    manager.define_singleton_method(:stop_session) { |_id| stopped = true }

    runner.send(:pause_if_idle, "thread-12345678", persisted)
    assert_not stopped
  end

  test "pause_if_idle stops idle sessions" do
    runner = Earl::Runner.new
    persisted = Earl::SessionStore::PersistedSession.new(
      is_paused: false,
      last_activity_at: (Time.now - 7200).iso8601
    )

    stopped = false
    manager = runner.instance_variable_get(:@session_manager)
    manager.define_singleton_method(:stop_session) { |_id| stopped = true }

    runner.send(:pause_if_idle, "thread-12345678", persisted)
    assert stopped
  end

  test "handle_reaction sends answer when thread found and session exists" do
    runner = Earl::Runner.new
    handler = runner.instance_variable_get(:@question_handler)
    handler.define_singleton_method(:handle_reaction) { |**_args| { tool_use_id: "tu-1", answer_text: "yes" } }

    # Override find_thread_for_question to return a thread_id
    runner.define_singleton_method(:find_thread_for_question) { |_id| "thread-12345678" }

    sent_messages = []
    mock_session = Object.new
    mock_session.define_singleton_method(:send_message) { |text| sent_messages << text }

    manager = runner.instance_variable_get(:@session_manager)
    manager.define_singleton_method(:get) { |_id| mock_session }

    runner.send(:handle_reaction, post_id: "post-1", emoji_name: "one")
    assert_equal [ "yes" ], sent_messages
  end

  test "handle_reaction skips send when session is nil" do
    runner = Earl::Runner.new
    handler = runner.instance_variable_get(:@question_handler)
    handler.define_singleton_method(:handle_reaction) { |**_args| { tool_use_id: "tu-1", answer_text: "yes" } }

    # Override find_thread_for_question to return a thread_id
    runner.define_singleton_method(:find_thread_for_question) { |_id| "thread-12345678" }

    # session_manager.get returns nil
    manager = runner.instance_variable_get(:@session_manager)
    manager.define_singleton_method(:get) { |_id| nil }

    # Should not raise (session&.send_message with nil session)
    assert_nothing_raised do
      runner.send(:handle_reaction, post_id: "post-1", emoji_name: "one")
    end
  end

  test "shutdown kills idle_checker_thread when present" do
    runner = Earl::Runner.new

    # Create a thread that mimics the idle checker
    thread = Thread.new { sleep 60 }
    runner.instance_variable_set(:@idle_checker_thread, thread)

    # Stub session_manager.pause_all and exit
    manager = runner.instance_variable_get(:@session_manager)
    manager.define_singleton_method(:pause_all) { }

    # Stub exit to prevent test from exiting
    exited = false
    runner.define_singleton_method(:exit) { |_code| exited = true }

    runner.send(:shutdown)
    sleep 0.05 # Allow thread to be killed
    assert_not thread.alive?
    assert exited
  end

  test "shutdown works when idle_checker_thread is nil" do
    runner = Earl::Runner.new
    runner.instance_variable_set(:@idle_checker_thread, nil)

    manager = runner.instance_variable_get(:@session_manager)
    manager.define_singleton_method(:pause_all) { }

    exited = false
    runner.define_singleton_method(:exit) { |_code| exited = true }

    # Should not raise even with nil thread
    assert_nothing_raised { runner.send(:shutdown) }
    assert exited
  end

  test "check_idle_sessions iterates persisted sessions" do
    runner = Earl::Runner.new
    store = Earl::SessionStore.new(path: File.join(Dir.tmpdir, "earl-test-idle-#{SecureRandom.hex(4)}.json"))
    runner.instance_variable_set(:@session_store, store)

    session = Earl::SessionStore::PersistedSession.new(
      claude_session_id: "sess-1", channel_id: "ch-1", working_dir: "/tmp",
      started_at: Time.now.iso8601, last_activity_at: Time.now.iso8601,
      is_paused: false, message_count: 0
    )
    store.save("thread-12345678", session)

    assert_nothing_raised { runner.send(:check_idle_sessions) }
  ensure
    FileUtils.rm_f(store.instance_variable_get(:@path)) if store
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

  def mock_stats(total_input_tokens: 0, total_output_tokens: 0, context_window: nil,
                  turn_input_tokens: 0, cache_read_tokens: 0, cache_creation_tokens: 0)
    Earl::ClaudeSession::Stats.new(
      total_cost: 0.0, total_input_tokens: total_input_tokens, total_output_tokens: total_output_tokens,
      turn_input_tokens: turn_input_tokens, turn_output_tokens: 0,
      cache_read_tokens: cache_read_tokens, cache_creation_tokens: cache_creation_tokens,
      context_window: context_window
    )
  end
end
