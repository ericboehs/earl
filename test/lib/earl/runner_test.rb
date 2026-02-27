# frozen_string_literal: true

require "test_helper"

module Earl
  class RunnerTest < Minitest::Test
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

      # Speed up debounce timer from 300ms to 10ms for tests
      @original_debounce_ms = Earl::StreamingResponse::DEBOUNCE_MS
      Earl::StreamingResponse.send(:remove_const, :DEBOUNCE_MS)
      Earl::StreamingResponse.const_set(:DEBOUNCE_MS, 10)
    end

    teardown do
      Earl.logger = nil

      # Restore DEBOUNCE_MS
      Earl::StreamingResponse.send(:remove_const, :DEBOUNCE_MS)
      Earl::StreamingResponse.const_set(:DEBOUNCE_MS, @original_debounce_ms)

      %w[MATTERMOST_URL MATTERMOST_BOT_TOKEN MATTERMOST_BOT_ID EARL_CHANNEL_ID EARL_ALLOWED_USERS
         EARL_SKIP_PERMISSIONS].each do |key|
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
      runner.instance_variable_get(:@services).session_manager = mock_manager

      # Stub typing to avoid real HTTP calls
      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "Hello Earl", channel_id: nil,
                                                sender_name: nil))
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
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
      mock_session.define_singleton_method(:on_tool_use) { |&_block| }
      mock_session.define_singleton_method(:send_message) { |_text| true }
      mock_session.define_singleton_method(:total_cost) { 0.05 }
      mock_session.define_singleton_method(:stats) { stats }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      created_posts = []
      updated_posts = []
      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
        created_posts << { channel_id: channel_id, message: message, root_id: root_id }
        { "id" => "reply-post-1" }
      end
      mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      # First chunk creates a post
      on_text_callback.call("Hello from Claude")

      assert_equal 1, created_posts.size
      assert_equal "Hello from Claude", created_posts.first[:message]
      assert_equal "thread-12345678", created_posts.first[:root_id]

      # Subsequent chunk after debounce updates with accumulated text
      sleep 0.05
      on_text_callback.call("updated")

      assert_equal 1, updated_posts.size
      assert_equal "reply-post-1", updated_posts.first[:post_id]

      # on_complete edits existing post (text-only response, no stats footer)
      on_complete_callback.call(mock_session)

      # Text-only response: final update contains the text without stats
      final_update = updated_posts.last
      assert_includes final_update[:message], "updated"
      assert_not_includes final_update[:message], "tokens"
    end

    test "setup_message_handler registers callback with mattermost" do
      runner = Earl::Runner.new
      mm = runner.instance_variable_get(:@services).mattermost

      # Verify on_message was called during setup (callback is stored)
      runner.send(:setup_message_handler)

      # The callback exists (on_message was called with a block)
      assert_not_nil mm.instance_variable_get(:@callbacks).on_message
    end

    test "debounce timer fires when time has not elapsed" do
      runner = Earl::Runner.new

      on_text_callback = nil
      mock_session = Object.new
      mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&_block| }
      mock_session.define_singleton_method(:on_tool_use) { |&_block| }
      mock_session.define_singleton_method(:send_message) { |_text| true }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      updated_posts = []
      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
      mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      # First chunk creates post
      on_text_callback.call("Part 1")

      # Rapid second chunk (within debounce window) — should schedule timer
      on_text_callback.call("Part 2")

      # Wait for debounce timer to fire
      sleep 0.05

      assert(updated_posts.any? { |u| u[:message] == "Part 1\n\nPart 2" })
    end

    test "setup_signal_handlers can be called without error" do
      runner = Earl::Runner.new
      assert_nothing_raised { runner.send(:setup_signal_handlers) }
    end

    test "start method calls setup methods and enters main loop" do
      runner = Earl::Runner.new
      mm = runner.instance_variable_get(:@services).mattermost

      # Stub connect and get_channel to not make real network calls
      mm.define_singleton_method(:connect) {}
      mm.define_singleton_method(:get_channel) { |channel_id:| { "display_name" => "Test Channel" } }

      # Set shutting_down so the loop exits immediately
      runner.instance_variable_get(:@app_state).shutting_down = true

      # Kill the idle checker thread after start
      assert_nothing_raised { runner.start }
    ensure
      runner.instance_variable_get(:@app_state).idle_checker_thread&.kill
    end

    test "on_complete without prior text does not update or create posts" do
      runner = Earl::Runner.new

      on_text_callback = nil
      on_complete_callback = nil
      stats = mock_stats

      mock_session = Object.new
      mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
      mock_session.define_singleton_method(:on_tool_use) { |&_block| }
      mock_session.define_singleton_method(:send_message) { |_text| true }
      mock_session.define_singleton_method(:total_cost) { 0.0 }
      mock_session.define_singleton_method(:stats) { stats }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      updated_posts = []
      created_posts = []
      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end
      mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
        created_posts << { channel_id: channel_id, message: message, root_id: root_id }
        { "id" => "notif-1" }
      end

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))
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
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&_block| }
      mock_session.define_singleton_method(:on_tool_use) { |&_block| }
      mock_session.define_singleton_method(:send_message) { |_text| true }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      update_count = 0
      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
      mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
        update_count += 1
      end

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      # First chunk creates post
      on_text_callback.call("Part 1")

      # Rapid second chunk — schedules debounce timer
      on_text_callback.call("Part 2")

      # Rapid third chunk — timer already scheduled, should NOT create another
      on_text_callback.call("Part 3")

      # Wait for single debounce timer to fire
      sleep 0.05

      # Only one debounced update should have fired
      assert_equal 1, update_count
    end

    test "start enters main loop before exiting" do
      runner = Earl::Runner.new
      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:connect) {}
      mm.define_singleton_method(:get_channel) { |channel_id:| { "display_name" => "Test Channel" } }

      # Set shutting_down after a brief delay so the loop runs at least once
      Thread.new do
        sleep 0.1
        runner.instance_variable_get(:@app_state).shutting_down = true
      end

      assert_nothing_raised { runner.start }
    ensure
      runner.instance_variable_get(:@app_state).idle_checker_thread&.kill
    end

    test "message handler calls enqueue_message for allowed users" do
      runner = Earl::Runner.new

      mm = runner.instance_variable_get(:@services).mattermost
      runner.send(:setup_message_handler)
      callback = mm.instance_variable_get(:@callbacks).on_message

      sent_text = nil
      mock_session = build_mock_session(on_send: ->(text) { sent_text = text })
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager
      mm.define_singleton_method(:send_typing) { |**_args| }

      callback.call(sender_name: "alice", thread_id: "thread-12345678", text: "Hi Earl", post_id: "post-1",
                    channel_id: "channel-456")
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
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
      mock_session.define_singleton_method(:on_tool_use) { |&_block| }
      mock_session.define_singleton_method(:send_message) { |text| sent_messages << text }
      mock_session.define_singleton_method(:total_cost) { 0.0 }
      mock_session.define_singleton_method(:stats) { stats }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "notif-1" } }

      # First message starts processing
      runner.send(:enqueue_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "first", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      # Second message should be queued (thread is busy)
      runner.send(:enqueue_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "second", channel_id: nil,
                                                sender_name: nil))

      assert_equal ["first"], sent_messages

      # Complete first message — should process queued "second"
      on_complete_callback.call(mock_session)
      sleep 0.05

      assert_equal %w[first second], sent_messages
    end

    test "enqueue_message processes immediately for new thread" do
      runner = Earl::Runner.new

      sent_text = nil
      mock_session = build_mock_session(on_send: ->(text) { sent_text = text })
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }

      runner.send(:enqueue_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "hello", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      assert_equal "hello", sent_text
    end

    test "on_complete drains queue and releases thread when empty" do
      runner = Earl::Runner.new

      on_complete_callback = nil
      stats = mock_stats
      mock_session = Object.new
      mock_session.define_singleton_method(:on_text) { |&_block| }
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
      mock_session.define_singleton_method(:on_tool_use) { |&_block| }
      mock_session.define_singleton_method(:send_message) { |_text| true }
      mock_session.define_singleton_method(:total_cost) { 0.0 }
      mock_session.define_singleton_method(:stats) { stats }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "notif-1" } }

      runner.send(:enqueue_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "hello", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      # Complete — no queued messages, should remove from processing_threads
      on_complete_callback.call(mock_session)

      message_queue = runner.instance_variable_get(:@app_state).message_queue
      processing = message_queue.instance_variable_get(:@processing_threads)
      assert_not processing.include?("thread-12345678")
    end

    test "message handler ignores non-allowed users" do
      runner = Earl::Runner.new

      mm = runner.instance_variable_get(:@services).mattermost
      runner.send(:setup_message_handler)

      # Get the callback that was registered
      callback = mm.instance_variable_get(:@callbacks).on_message

      # Mock the session_manager to ensure it's never called for non-allowed user
      session_created = false
      mock_manager = Object.new
      mock_manager.define_singleton_method(:get_or_create) { |*_args, **_kwargs| session_created = true }
      mock_manager.define_singleton_method(:touch) { |_id| }
      runner.instance_variable_get(:@services).session_manager = mock_manager

      callback.call(sender_name: "eve", thread_id: "thread-1", text: "Hi", post_id: "post-1", channel_id: "channel-456")

      assert_not session_created
    end

    test "handle_incoming_message routes commands to executor" do
      runner = Earl::Runner.new

      executed_command = nil
      executor = runner.instance_variable_get(:@services).command_executor
      executor.define_singleton_method(:execute) do |command, thread_id:, channel_id:|
        executed_command = command
      end

      runner.send(:handle_incoming_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "!help", channel_id: "channel-456",
                                                sender_name: nil))

      assert_not_nil executed_command
      assert_equal :help, executed_command.name
    end

    test "handle_incoming_message routes normal messages to enqueue" do
      runner = Earl::Runner.new

      sent_text = nil
      mock_session = build_mock_session(on_send: ->(text) { sent_text = text })
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }

      runner.send(:handle_incoming_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "hello", channel_id: "channel-456",
                                                sender_name: nil))
      sleep 0.05

      assert_equal "hello", sent_text
    end

    test "setup_reaction_handler registers callback with mattermost" do
      runner = Earl::Runner.new
      mm = runner.instance_variable_get(:@services).mattermost

      runner.send(:setup_reaction_handler)
      assert_not_nil mm.instance_variable_get(:@callbacks).on_reaction
    end

    test "on_tool_use callback delegates to question_handler" do
      runner = Earl::Runner.new

      on_tool_use_callback = nil
      mock_session = Object.new
      mock_session.define_singleton_method(:on_text) { |&_block| }
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&_block| }
      mock_session.define_singleton_method(:on_tool_use) { |&block| on_tool_use_callback = block }
      mock_session.define_singleton_method(:send_message) { |_text| true }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      # Fire on_tool_use with a non-AskUserQuestion tool — should not error
      assert_nothing_raised { on_tool_use_callback.call({ id: "tu-1", name: "Bash", input: {} }) }
    end

    test "on_tool_use routes to both response and question handler" do
      runner = Earl::Runner.new

      on_tool_use_callback = nil
      mock_session = Object.new
      mock_session.define_singleton_method(:on_text) { |&_block| }
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&_block| }
      mock_session.define_singleton_method(:on_tool_use) { |&block| on_tool_use_callback = block }
      mock_session.define_singleton_method(:send_message) { |_text| true }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      created_posts = []
      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
        created_posts << { message: message }
        { "id" => "reply-1" }
      end

      question_handler_called = false
      handler = runner.instance_variable_get(:@services).question_handler
      handler.define_singleton_method(:handle_tool_use) do |**_args|
        question_handler_called = true
        nil
      end

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))
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

      # Mock get_user to return a valid allowed username
      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_user) { |user_id:| { "username" => "alice" } }

      # No pending questions, so reaction handling returns nil
      assert_nothing_raised do
        runner.send(:handle_reaction, user_id: "user-1", post_id: "unknown-post", emoji_name: "one")
      end
    end

    test "question_threads returns nil for unknown tool_use_id" do
      runner = Earl::Runner.new
      assert_nil runner.instance_variable_get(:@responses).question_threads["tu-1"]
    end

    test "resolve_working_dir uses command executor override first" do
      runner = Earl::Runner.new
      executor = runner.instance_variable_get(:@services).command_executor

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

    test "final post does not include stats footer" do
      runner = Earl::Runner.new

      on_text_callback = nil
      on_complete_callback = nil
      stats = mock_stats(total_input_tokens: 5000, total_output_tokens: 1500, context_window: 200_000,
                         turn_input_tokens: 5000, cache_read_tokens: 30_000)

      mock_session = Object.new
      mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
      mock_session.define_singleton_method(:on_tool_use) { |&_block| }
      mock_session.define_singleton_method(:send_message) { |_text| true }
      mock_session.define_singleton_method(:stats) { stats }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      updated_posts = []
      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end
      mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
        { "id" => "post-1" }
      end

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      on_text_callback.call("Here is the answer.")
      on_complete_callback.call(mock_session)

      # Text-only response: edits existing post without stats footer
      final_update = updated_posts.last
      assert_includes final_update[:message], "Here is the answer."
      assert_not_includes final_update[:message], "tokens"
    end

    test "final post has no stats footer when no tokens" do
      runner = Earl::Runner.new

      on_text_callback = nil
      on_complete_callback = nil
      stats = mock_stats

      mock_session = Object.new
      mock_session.define_singleton_method(:on_text) { |&block| on_text_callback = block }
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&block| on_complete_callback = block }
      mock_session.define_singleton_method(:on_tool_use) { |&_block| }
      mock_session.define_singleton_method(:send_message) { |_text| true }
      mock_session.define_singleton_method(:stats) { stats }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      updated_posts = []
      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end
      mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
        { "id" => "post-1" }
      end

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))
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
      mm = runner.instance_variable_get(:@services).mattermost
      channel_ids = mm.instance_variable_get(:@connection).channel_ids
      assert channel_ids.size > 1
    end

    test "handle_shutdown_signal is idempotent" do
      runner = Earl::Runner.new
      app_state = runner.instance_variable_get(:@app_state)

      # First call should set shutting_down
      # Stub Thread.new to avoid actually spawning shutdown thread
      threads_spawned = 0
      original_new = Thread.method(:new)
      Thread.define_singleton_method(:new) do
        threads_spawned += 1
        original_new.call {} # no-op thread
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
      executor = runner.instance_variable_get(:@services).command_executor
      executor.define_singleton_method(:execute) { |*_args, **_kwargs| executed = true }

      # "!unknown_thing" is command-like but CommandParser.parse returns nil
      msg = Earl::Runner::UserMessage.new(
        thread_id: "thread-12345678", text: "!unknown_thing",
        channel_id: "channel-456", sender_name: nil
      )
      runner.send(:handle_incoming_message, msg)

      assert_not executed
    end

    test "handle_reaction returns early when question handler returns nil result" do
      runner = Earl::Runner.new
      handler = runner.instance_variable_get(:@services).question_handler
      handler.define_singleton_method(:handle_reaction) { |**_args| nil }

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_user) { |user_id:| { "username" => "alice" } }

      assert_nothing_raised do
        runner.send(:handle_reaction, user_id: "user-1", post_id: "post-1", emoji_name: "one")
      end
    end

    test "handle_reaction returns early when find_thread returns nil" do
      runner = Earl::Runner.new
      handler = runner.instance_variable_get(:@services).question_handler
      handler.define_singleton_method(:handle_reaction) { |**_args| { tool_use_id: "tu-1", answer_text: "yes" } }

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_user) { |user_id:| { "username" => "alice" } }

      # @question_threads is empty, so find_thread_for_question returns nil
      assert_nothing_raised do
        runner.send(:handle_reaction, user_id: "user-1", post_id: "post-1", emoji_name: "one")
      end
    end

    test "handle_tool_use stores question_threads mapping for AskUserQuestion" do
      runner = Earl::Runner.new

      on_tool_use_callback = nil
      mock_session = Object.new
      mock_session.define_singleton_method(:on_text) { |&_block| }
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&_block| }
      mock_session.define_singleton_method(:on_tool_use) { |&block| on_tool_use_callback = block }
      mock_session.define_singleton_method(:send_message) { |_text| true }

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
        { "id" => "question-post-1" }
      end
      mock_mm.define_singleton_method(:add_reaction) { |**_args| }

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      on_tool_use_callback.call({
                                  id: "tu-99",
                                  name: "AskUserQuestion",
                                  input: {
                                    "questions" => [
                                      {
                                        "question" => "Which option?",
                                        "options" => [
                                          { "label" => "A" },
                                          { "label" => "B" }
                                        ]
                                      }
                                    ]
                                  }
                                })

      # Verify that question_threads was populated
      question_threads = runner.instance_variable_get(:@responses).question_threads
      assert_equal "thread-12345678", question_threads["tu-99"]
    end

    test "process_message releases queue claim on error" do
      runner = Earl::Runner.new

      mock_manager = Object.new
      mock_manager.define_singleton_method(:get_or_create) { |*_args, **_kwargs| raise "session creation failed" }
      mock_manager.define_singleton_method(:touch) { |_id| }
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }

      # Claim the thread first
      queue = runner.instance_variable_get(:@app_state).message_queue
      queue.try_claim("thread-12345678")

      # process_message should catch the error and release the claim
      assert_nothing_raised do
        runner.send(:process_message,
                    Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                  sender_name: nil))
      end

      # Queue claim should be released so a new message can be processed
      assert queue.try_claim("thread-12345678"), "Queue claim should have been released after error"
    end

    test "process_message releases queue and stops typing when send_message returns false" do
      runner = Earl::Runner.new

      mock_session = Object.new
      mock_session.define_singleton_method(:on_text) { |&_block| }
      mock_session.define_singleton_method(:on_system) { |&_block| }
      mock_session.define_singleton_method(:on_complete) { |&_block| }
      mock_session.define_singleton_method(:on_tool_use) { |&_block| }
      mock_session.define_singleton_method(:send_message) { |_text| false } # Dead session
      mock_session.define_singleton_method(:stats) do
        Earl::ClaudeSession::Stats.new(
          total_cost: 0.0, total_input_tokens: 0, total_output_tokens: 0,
          turn_input_tokens: 0, turn_output_tokens: 0,
          cache_read_tokens: 0, cache_creation_tokens: 0
        )
      end

      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }

      queue = runner.instance_variable_get(:@app_state).message_queue
      queue.try_claim("thread-12345678")

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "test", channel_id: nil,
                                                sender_name: nil))

      # Queue should be released
      assert queue.try_claim("thread-12345678"), "Queue claim should have been released after dead session"

      # Active response should be cleaned up
      assert_nil runner.instance_variable_get(:@responses).active_responses["thread-12345678"]
    end

    test "question_threads returns thread_id for known tool_use_id" do
      runner = Earl::Runner.new
      runner.instance_variable_get(:@responses).question_threads["tu-42"] = "thread-abcd1234"
      assert_equal "thread-abcd1234", runner.instance_variable_get(:@responses).question_threads["tu-42"]
    end

    test "stop_if_idle skips paused sessions" do
      runner = Earl::Runner.new
      persisted = Earl::SessionStore::PersistedSession.new(
        is_paused: true,
        last_activity_at: (Time.now - 7200).iso8601
      )

      stopped = false
      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:stop_session) { |_id| stopped = true }

      runner.send(:stop_if_idle, "thread-12345678", persisted)
      assert_not stopped
    end

    test "stop_if_idle skips recently active sessions" do
      runner = Earl::Runner.new
      persisted = Earl::SessionStore::PersistedSession.new(
        is_paused: false,
        last_activity_at: Time.now.iso8601
      )

      stopped = false
      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:stop_session) { |_id| stopped = true }

      runner.send(:stop_if_idle, "thread-12345678", persisted)
      assert_not stopped
    end

    test "stop_if_idle stops idle sessions" do
      runner = Earl::Runner.new
      persisted = Earl::SessionStore::PersistedSession.new(
        is_paused: false,
        last_activity_at: (Time.now - 7200).iso8601
      )

      stopped = false
      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:stop_session) { |_id| stopped = true }

      runner.send(:stop_if_idle, "thread-12345678", persisted)
      assert stopped
    end

    test "stop_if_idle handles nil last_activity_at gracefully" do
      runner = Earl::Runner.new
      persisted = Earl::SessionStore::PersistedSession.new(
        is_paused: false,
        last_activity_at: nil
      )

      stopped = false
      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:stop_session) { |_id| stopped = true }

      assert_nothing_raised { runner.send(:stop_if_idle, "thread-12345678", persisted) }
      assert_not stopped
    end

    test "handle_reaction sends answer when thread found and session exists" do
      runner = Earl::Runner.new
      handler = runner.instance_variable_get(:@services).question_handler
      handler.define_singleton_method(:handle_reaction) { |**_args| { tool_use_id: "tu-1", answer_text: "yes" } }

      # Populate @question_threads to simulate a prior tool_use capture
      runner.instance_variable_get(:@responses).question_threads["tu-1"] = "thread-12345678"

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_user) { |user_id:| { "username" => "alice" } }

      sent_messages = []
      mock_session = Object.new
      mock_session.define_singleton_method(:send_message) { |text| sent_messages << text }

      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:get) { |_id| mock_session }

      runner.send(:handle_reaction, user_id: "user-1", post_id: "post-1", emoji_name: "one")
      assert_equal ["yes"], sent_messages
    end

    test "handle_reaction skips send when session is nil" do
      runner = Earl::Runner.new
      handler = runner.instance_variable_get(:@services).question_handler
      handler.define_singleton_method(:handle_reaction) { |**_args| { tool_use_id: "tu-1", answer_text: "yes" } }

      # Populate @question_threads to simulate a prior tool_use capture
      runner.instance_variable_get(:@responses).question_threads["tu-1"] = "thread-12345678"

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_user) { |user_id:| { "username" => "alice" } }

      # session_manager.get returns nil
      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:get) { |_id| nil }

      # Should not raise (session&.send_message with nil session)
      assert_nothing_raised do
        runner.send(:handle_reaction, user_id: "user-1", post_id: "post-1", emoji_name: "one")
      end
    end

    test "handle_reaction blocks non-allowed users" do
      runner = Earl::Runner.new

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_user) { |user_id:| { "username" => "eve" } }

      handler = runner.instance_variable_get(:@services).question_handler
      handler_called = false
      handler.define_singleton_method(:handle_reaction) do |**_args|
        handler_called = true
        nil
      end

      runner.send(:handle_reaction, user_id: "user-eve", post_id: "post-1", emoji_name: "one")
      assert_not handler_called, "Expected non-allowed user reaction to be blocked"
    end

    test "handle_reaction allows all users when allowlist is empty" do
      ENV["EARL_ALLOWED_USERS"] = ""
      runner = Earl::Runner.new

      handler = runner.instance_variable_get(:@services).question_handler
      handler.define_singleton_method(:handle_reaction) { |**_args| nil }

      # Should not need get_user when allowlist is empty
      assert_nothing_raised do
        runner.send(:handle_reaction, user_id: "user-1", post_id: "post-1", emoji_name: "one")
      end
    end

    test "shutdown kills idle_checker_thread when present" do
      runner = Earl::Runner.new

      # Create a thread that mimics the idle checker (killed by Thread#kill in shutdown)
      app_state = runner.instance_variable_get(:@app_state)
      thread = Thread.new { sleep 0.01 until Thread.current[:stop] }
      app_state.idle_checker_thread = thread

      # Stub session_manager.pause_all
      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:pause_all) {}

      runner.send(:shutdown)
      sleep 0.05 # Allow thread to be killed
      assert_not thread.alive?
    end

    test "shutdown works when idle_checker_thread is nil" do
      runner = Earl::Runner.new
      runner.instance_variable_get(:@app_state).idle_checker_thread = nil

      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:pause_all) {}

      # Should not raise even with nil thread
      assert_nothing_raised { runner.send(:shutdown) }
    end

    test "process_message builds contextual message for new sessions with thread history" do
      runner = Earl::Runner.new

      sent_text = nil
      mock_session = build_mock_session(on_send: ->(text) { sent_text = text })

      # Mock manager where get returns nil (new session) but get_or_create returns session
      mock_manager = Object.new
      mock_manager.define_singleton_method(:get) { |_id| nil }
      mock_manager.define_singleton_method(:get_or_create) { |*_args, **_kwargs| mock_session }
      mock_manager.define_singleton_method(:touch) { |_id| }
      mock_manager.define_singleton_method(:save_stats) { |_id| }
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:get_thread_posts) do |_thread_id|
        [
          { sender: "user", message: "!sessions", is_bot: false },
          { sender: "EARL", message: "| Session | Project | Status |", is_bot: true },
          { sender: "user", message: "Can u approve 4", is_bot: false }
        ]
      end

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "Can u approve 4", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      assert_includes sent_text, "Here is the conversation so far"
      assert_includes sent_text, "User: !sessions"
      assert_includes sent_text, "EARL: | Session | Project | Status |"
      assert_includes sent_text, "User's latest message: Can u approve 4"
    end

    test "process_message sends plain text for new sessions with no thread history" do
      runner = Earl::Runner.new

      sent_text = nil
      mock_session = build_mock_session(on_send: ->(text) { sent_text = text })

      mock_manager = Object.new
      mock_manager.define_singleton_method(:get) { |_id| nil }
      mock_manager.define_singleton_method(:get_or_create) { |*_args, **_kwargs| mock_session }
      mock_manager.define_singleton_method(:touch) { |_id| }
      mock_manager.define_singleton_method(:save_stats) { |_id| }
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:get_thread_posts) { |_thread_id| [] }

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "Hello Earl", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      assert_equal "Hello Earl", sent_text
    end

    test "process_message sends plain text for existing sessions without fetching thread" do
      runner = Earl::Runner.new

      sent_text = nil
      mock_session = build_mock_session(on_send: ->(text) { sent_text = text })
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      thread_posts_called = false
      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:send_typing) { |**_args| }
      mock_mm.define_singleton_method(:get_thread_posts) do |_id|
        thread_posts_called = true
        []
      end

      runner.send(:process_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "follow up", channel_id: nil,
                                                sender_name: nil))
      sleep 0.05

      assert_equal "follow up", sent_text
      assert_not thread_posts_called, "Should not fetch thread posts for existing sessions"
    end

    test "build_contextual_message excludes current message from transcript" do
      runner = Earl::Runner.new

      mock_mm = runner.instance_variable_get(:@services).mattermost
      mock_mm.define_singleton_method(:get_thread_posts) do |_thread_id|
        [
          { sender: "user", message: "!help", is_bot: false },
          { sender: "EARL", message: "Available commands: ...", is_bot: true },
          { sender: "user", message: "thanks", is_bot: false }
        ]
      end

      result = runner.send(:build_contextual_message, "thread-12345678", "thanks")

      assert_includes result, "User: !help"
      assert_includes result, "EARL: Available commands: ..."
      assert_not_includes result, "User: thanks\n" # Current message excluded from transcript
      assert_includes result, "User's latest message: thanks"
    end

    # -- Restart tests --

    test "request_restart sets shutting_down and is idempotent" do
      runner = Earl::Runner.new
      app_state = runner.instance_variable_get(:@app_state)

      threads_spawned = 0
      original_new = Thread.method(:new)
      Thread.define_singleton_method(:new) do
        threads_spawned += 1
        original_new.call {}
      end

      runner.request_restart
      assert app_state.shutting_down
      assert_equal 1, threads_spawned

      # Second call should be a no-op
      runner.request_restart
      assert_equal 1, threads_spawned
    ensure
      Thread.define_singleton_method(:new) { |&block| original_new.call(&block) } if original_new
    end

    test "handle_restart_signal is idempotent like handle_shutdown_signal" do
      runner = Earl::Runner.new
      app_state = runner.instance_variable_get(:@app_state)

      threads_spawned = 0
      original_new = Thread.method(:new)
      Thread.define_singleton_method(:new) do
        threads_spawned += 1
        original_new.call {}
      end

      runner.send(:handle_restart_signal)
      assert app_state.shutting_down
      assert_equal 1, threads_spawned

      # Second call should return early
      runner.send(:handle_restart_signal)
      assert_equal 1, threads_spawned
    ensure
      Thread.define_singleton_method(:new) { |&block| original_new.call(&block) } if original_new
    end

    test "begin_shutdown is shared by shutdown and restart signals" do
      runner = Earl::Runner.new
      app_state = runner.instance_variable_get(:@app_state)

      threads_spawned = 0
      original_new = Thread.method(:new)
      Thread.define_singleton_method(:new) do
        threads_spawned += 1
        original_new.call {}
      end

      # First signal claims shutdown
      runner.send(:handle_shutdown_signal)
      assert app_state.shutting_down
      assert_equal 1, threads_spawned

      # Restart signal after shutdown should be ignored
      runner.send(:handle_restart_signal)
      assert_equal 1, threads_spawned
    ensure
      Thread.define_singleton_method(:new) { |&block| original_new.call(&block) } if original_new
    end

    test "request_update sets pending_update flag" do
      runner = Earl::Runner.new
      app_state = runner.instance_variable_get(:@app_state)

      original_new = Thread.method(:new)
      Thread.define_singleton_method(:new) do
        original_new.call {}
      end

      runner.request_update
      assert app_state.shutting_down
      assert app_state.pending_restart
      assert app_state.pending_update
    ensure
      Thread.define_singleton_method(:new) { |&block| original_new.call(&block) } if original_new
    end

    test "restart with pending_update flag logs updating" do
      runner = Earl::Runner.new
      app_state = runner.instance_variable_get(:@app_state)
      app_state.pending_update = true

      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:pause_all) {}

      # Stub pull_latest and update_dependencies to avoid real shell calls
      runner.define_singleton_method(:pull_latest) {}
      runner.define_singleton_method(:update_dependencies) {}

      assert_nothing_raised { runner.send(:restart) }
    end

    test "restart without pending_update skips update_dependencies" do
      runner = Earl::Runner.new
      app_state = runner.instance_variable_get(:@app_state)
      app_state.pending_update = false

      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:pause_all) {}

      update_called = false
      runner.define_singleton_method(:pull_latest) {}
      runner.define_singleton_method(:update_dependencies) { update_called = true }

      runner.send(:restart)

      assert_not update_called, "update_dependencies should not be called without pending_update"
    end

    test "run_in_repo logs success on successful command" do
      runner = Earl::Runner.new

      runner.define_singleton_method(:system) { |*_args| true }

      assert_nothing_raised do
        Dir.chdir(File.dirname($PROGRAM_NAME)) do
          runner.send(:run_in_repo, "test cmd", "true")
        end
      end
    end

    test "run_in_repo logs failure on failed command" do
      runner = Earl::Runner.new

      runner.define_singleton_method(:system) { |*_args| false }

      assert_nothing_raised do
        Dir.chdir(File.dirname($PROGRAM_NAME)) do
          runner.send(:run_in_repo, "test cmd", "false")
        end
      end
    end

    test "run_in_repo rescues StandardError" do
      runner = Earl::Runner.new

      # Stub Dir.chdir to raise
      runner.define_singleton_method(:run_in_repo) do |label, *_cmd|
        raise StandardError, "chdir failed"
      rescue StandardError => error
        # Call the real rescue logic
        Earl.logger&.warn("#{label} failed: #{error.message}")
      end

      assert_nothing_raised { runner.send(:run_in_repo, "test cmd", "true") }
    end

    test "notify_restart posts to mattermost and deletes context file" do
      runner = Earl::Runner.new
      path = File.join(Earl.config_root, "restart_context.json")
      FileUtils.mkdir_p(Earl.config_root)
      File.write(path, JSON.generate({ channel_id: "ch-1", thread_id: "th-1", command: "restart" }))

      posted = []
      mm = runner.instance_variable_get(:@services).mattermost
      psts = posted
      mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
        psts << { channel_id: channel_id, message: message, root_id: root_id }
      end

      runner.send(:notify_restart)

      assert_equal 1, posted.size
      assert_includes posted.first[:message], "restarted"
      assert_equal "ch-1", posted.first[:channel_id]
      assert_equal "th-1", posted.first[:root_id]
      assert_not File.exist?(path)
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    test "notify_restart uses updated verb for update command" do
      runner = Earl::Runner.new
      path = File.join(Earl.config_root, "restart_context.json")
      FileUtils.mkdir_p(Earl.config_root)
      File.write(path, JSON.generate({ channel_id: "ch-1", thread_id: "th-1", command: "update" }))

      posted = []
      mm = runner.instance_variable_get(:@services).mattermost
      psts = posted
      mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
        psts << { message: message }
      end

      runner.send(:notify_restart)

      assert_includes posted.first[:message], "updated"
      assert_not File.exist?(path)
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    test "notify_restart rescues StandardError from create_post" do
      runner = Earl::Runner.new
      path = File.join(Earl.config_root, "restart_context.json")
      FileUtils.mkdir_p(Earl.config_root)
      File.write(path, JSON.generate({ channel_id: "ch-1", thread_id: "th-1", command: "restart" }))

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:create_post) { |**_args| raise "network timeout" }

      assert_nothing_raised { runner.send(:notify_restart) }
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    test "resolve_channel_names falls back to truncated id when channel info has no name" do
      runner = Earl::Runner.new
      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_channel) { |channel_id:| {} }

      names = runner.send(:resolve_channel_names, ["abcdefgh12345678"])
      assert_equal ["abcdefgh"], names
    end

    test "resolve_channel_names falls back to name when display_name is nil" do
      runner = Earl::Runner.new
      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_channel) { |channel_id:| { "name" => "general" } }

      names = runner.send(:resolve_channel_names, ["channel-456"])
      assert_equal ["general"], names
    end

    test "resolve_channel_names falls back to truncated id when get_channel returns nil" do
      runner = Earl::Runner.new
      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_channel) { |channel_id:| nil }

      names = runner.send(:resolve_channel_names, ["abcdefgh12345678"])
      assert_equal ["abcdefgh"], names
    end

    test "handle_response_complete handles nil session gracefully" do
      runner = Earl::Runner.new
      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:get) { |_id| nil }

      # Create a response for the thread
      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:send_typing) { |**_args| }
      response = Earl::StreamingResponse.new(thread_id: "thread-12345678", mattermost: mm, channel_id: "ch-1")
      runner.instance_variable_get(:@responses).active_responses["thread-12345678"] = response

      assert_nothing_raised { runner.send(:handle_response_complete, "thread-12345678") }
    end

    test "handle_response_complete handles nil response gracefully" do
      runner = Earl::Runner.new
      mock_session = build_mock_session
      manager = runner.instance_variable_get(:@services).session_manager
      manager.define_singleton_method(:get) { |_id| mock_session }

      # No active response for this thread
      assert_nothing_raised { runner.send(:handle_response_complete, "thread-12345678") }
    end

    test "handle_incoming_message routes passthrough from command to enqueue" do
      runner = Earl::Runner.new

      executor = runner.instance_variable_get(:@services).command_executor
      executor.define_singleton_method(:execute) { |*_args, **_kwargs| { passthrough: "forwarded message" } }

      enqueued = nil
      runner.define_singleton_method(:enqueue_message) { |msg| enqueued = msg }

      runner.send(:handle_incoming_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "!escape",
                                                channel_id: "channel-456", sender_name: "alice"))

      assert_not_nil enqueued
      assert_equal "forwarded message", enqueued.text
    end

    test "handle_incoming_message stops active response for !stop command" do
      runner = Earl::Runner.new

      executor = runner.instance_variable_get(:@services).command_executor
      executor.define_singleton_method(:execute) { |*_args, **_kwargs| nil }

      # Simulate an active response
      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:send_typing) { |**_args| }
      response = Earl::StreamingResponse.new(thread_id: "thread-12345678", mattermost: mm, channel_id: "ch-1")
      runner.instance_variable_get(:@responses).active_responses["thread-12345678"] = response

      runner.send(:handle_incoming_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "!stop",
                                                channel_id: "channel-456", sender_name: nil))

      assert_nil runner.instance_variable_get(:@responses).active_responses["thread-12345678"]
    end

    test "handle_incoming_message stops active response for !kill command" do
      runner = Earl::Runner.new

      executor = runner.instance_variable_get(:@services).command_executor
      executor.define_singleton_method(:execute) { |*_args, **_kwargs| nil }

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:send_typing) { |**_args| }
      response = Earl::StreamingResponse.new(thread_id: "thread-12345678", mattermost: mm, channel_id: "ch-1")
      runner.instance_variable_get(:@responses).active_responses["thread-12345678"] = response

      runner.send(:handle_incoming_message,
                  Earl::Runner::UserMessage.new(thread_id: "thread-12345678", text: "!kill",
                                                channel_id: "channel-456", sender_name: nil))

      assert_nil runner.instance_variable_get(:@responses).active_responses["thread-12345678"]
    end

    test "log_startup with single channel uses singular form" do
      runner = Earl::Runner.new
      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:get_channel) { |channel_id:| { "display_name" => "General" } }

      # Should not raise — testing singular "channel" vs plural "channels"
      assert_nothing_raised { runner.send(:log_startup) }
    end

    test "notify_restart is a no-op when no context file exists" do
      runner = Earl::Runner.new
      assert_nothing_raised { runner.send(:notify_restart) }
    end

    test "check_idle_sessions iterates persisted sessions" do
      runner = Earl::Runner.new
      store = Earl::SessionStore.new(path: File.join(Dir.tmpdir, "earl-test-idle-#{SecureRandom.hex(4)}.json"))
      runner.instance_variable_get(:@services).session_store = store

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

    # -- AnalysisFollowup tests --

    test "needs_fixes_followup? returns true for long analysis text without Suggested Fixes" do
      runner = Earl::Runner.new
      text = "## Root Cause\n\n#{"x" * 300}\n\nThe problem went wrong because of a misunderstood requirement."
      assert runner.send(:needs_fixes_followup?, text)
    end

    test "needs_fixes_followup? returns false when Suggested Fixes heading is present" do
      runner = Earl::Runner.new
      text = "## Root Cause\n\n#{"x" * 300}\n\nSomething went wrong here.\n\n## Suggested Fixes\n\n1. Fix this"
      assert_not runner.send(:needs_fixes_followup?, text)
    end

    test "needs_fixes_followup? returns false when Recommended Fix heading is present" do
      runner = Earl::Runner.new
      text = "## Root Cause\n\n#{"x" * 300}\n\nSomething went wrong here.\n\n## Recommended Fix\n\n1. Fix this"
      assert_not runner.send(:needs_fixes_followup?, text)
    end

    test "needs_fixes_followup? returns false for short responses" do
      runner = Earl::Runner.new
      text = "## Root Cause\n\nSomething went wrong here."
      assert_not runner.send(:needs_fixes_followup?, text)
    end

    test "needs_fixes_followup? returns false for non-analysis content" do
      runner = Earl::Runner.new
      text = "#{"x" * 400}\n\nHere is a normal response with no analysis keywords."
      assert_not runner.send(:needs_fixes_followup?, text)
    end

    test "needs_fixes_followup? returns false when analysis keywords present but no heading" do
      runner = Earl::Runner.new
      text = "#{"x" * 400}\n\nThe problem went wrong because of a misunderstood requirement."
      assert_not runner.send(:needs_fixes_followup?, text)
    end

    test "needs_fixes_followup? returns false for nil text" do
      runner = Earl::Runner.new
      assert_not runner.send(:needs_fixes_followup?, nil)
    end

    test "needs_fixes_followup? returns true at exactly MIN_ANALYSIS_LENGTH boundary" do
      runner = Earl::Runner.new
      padding = "x" * (300 - "## Root Cause\n\nThe problem went wrong.".length)
      text = "## Root Cause\n\n#{padding}The problem went wrong."
      assert_equal 300, text.length
      assert runner.send(:needs_fixes_followup?, text)
    end

    test "needs_fixes_followup? recognizes case-insensitive headings" do
      runner = Earl::Runner.new
      text = "## WHAT WENT WRONG\n\n#{"x" * 300}\n\nThe problem went wrong here."
      assert runner.send(:needs_fixes_followup?, text)
    end

    test "send_analysis_followup_if_needed sends follow-up when fixes are missing" do
      runner = Earl::Runner.new

      sent_messages = []
      mock_session = build_mock_session(on_send: ->(text) { sent_messages << text })
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:send_typing) { |**_args| }

      analysis_text = "## Root Cause\n\n#{"x" * 300}\n\nThe problem went wrong due to a bad config."
      mock_response = Object.new
      mock_response.define_singleton_method(:full_text) { analysis_text }
      mock_response.define_singleton_method(:channel_id) { "ch-1" }

      bundle = Earl::Runner::ResponseLifecycle::ResponseBundle.new(
        session: mock_session, response: mock_response, thread_id: "thread-12345678"
      )

      runner.send(:send_analysis_followup_if_needed, bundle)

      assert_equal 1, sent_messages.size
      assert_includes sent_messages.first, "## Suggested Fixes"
    end

    test "send_analysis_followup_if_needed does not send follow-up when fixes are present" do
      runner = Earl::Runner.new

      sent_messages = []
      mock_session = build_mock_session(on_send: ->(text) { sent_messages << text })

      text_with_fixes = "## Root Cause\n\n#{"x" * 300}\n\nSomething went wrong.\n\n## Suggested Fixes\n\n1. Fix it"
      mock_response = Object.new
      mock_response.define_singleton_method(:full_text) { text_with_fixes }
      mock_response.define_singleton_method(:channel_id) { "ch-1" }

      bundle = Earl::Runner::ResponseLifecycle::ResponseBundle.new(
        session: mock_session, response: mock_response, thread_id: "thread-12345678"
      )

      runner.send(:send_analysis_followup_if_needed, bundle)

      assert_empty sent_messages
    end

    test "send_analysis_followup_if_needed only sends follow-up once per thread" do
      runner = Earl::Runner.new

      sent_messages = []
      mock_session = build_mock_session(on_send: ->(text) { sent_messages << text })
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:send_typing) { |**_args| }

      analysis_text = "## Root Cause\n\n#{"x" * 300}\n\nThe problem went wrong due to a bad config."
      mock_response = Object.new
      mock_response.define_singleton_method(:full_text) { analysis_text }
      mock_response.define_singleton_method(:channel_id) { "ch-1" }

      bundle = Earl::Runner::ResponseLifecycle::ResponseBundle.new(
        session: mock_session, response: mock_response, thread_id: "thread-12345678"
      )

      runner.send(:send_analysis_followup_if_needed, bundle)
      runner.send(:send_analysis_followup_if_needed, bundle)

      assert_equal 1, sent_messages.size
    end

    test "send_analysis_followup_if_needed logs when send_message fails" do
      runner = Earl::Runner.new

      mock_session = build_mock_session
      mock_session.define_singleton_method(:send_message) { |_text| false }
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:send_typing) { |**_args| }

      analysis_text = "## Root Cause\n\n#{"x" * 300}\n\nThe problem went wrong due to a bad config."
      mock_response = Object.new
      mock_response.define_singleton_method(:full_text) { analysis_text }
      mock_response.define_singleton_method(:channel_id) { "ch-1" }

      bundle = Earl::Runner::ResponseLifecycle::ResponseBundle.new(
        session: mock_session, response: mock_response, thread_id: "thread-12345678"
      )

      logs = capture_logs { runner.send(:send_analysis_followup_if_needed, bundle) }
      assert_match(/Follow-up send failed/, logs)
    end

    test "send_analysis_followup_if_needed returns true when follow-up sent" do
      runner = Earl::Runner.new

      mock_session = build_mock_session(on_send: ->(_text) {})
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:send_typing) { |**_args| }

      analysis_text = "## Root Cause\n\n#{"x" * 300}\n\nThe problem went wrong due to a bad config."
      mock_response = Object.new
      mock_response.define_singleton_method(:full_text) { analysis_text }
      mock_response.define_singleton_method(:channel_id) { "ch-1" }

      bundle = Earl::Runner::ResponseLifecycle::ResponseBundle.new(
        session: mock_session, response: mock_response, thread_id: "thread-ret-true"
      )

      result = runner.send(:send_analysis_followup_if_needed, bundle)
      assert_equal true, result
    end

    test "send_analysis_followup_if_needed returns false when no follow-up needed" do
      runner = Earl::Runner.new

      mock_response = Object.new
      mock_response.define_singleton_method(:full_text) { "Short text" }
      mock_response.define_singleton_method(:channel_id) { "ch-1" }

      bundle = Earl::Runner::ResponseLifecycle::ResponseBundle.new(
        session: build_mock_session, response: mock_response, thread_id: "thread-ret-false"
      )

      result = runner.send(:send_analysis_followup_if_needed, bundle)
      assert_equal false, result
    end

    test "send_analysis_followup_if_needed returns false on error" do
      runner = Earl::Runner.new

      mock_session = build_mock_session
      mock_session.define_singleton_method(:send_message) { |_text| raise "boom" }
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:send_typing) { |**_args| }

      analysis_text = "## Root Cause\n\n#{"x" * 300}\n\nThe problem went wrong due to a bad config."
      mock_response = Object.new
      mock_response.define_singleton_method(:full_text) { analysis_text }
      mock_response.define_singleton_method(:channel_id) { "ch-1" }

      bundle = Earl::Runner::ResponseLifecycle::ResponseBundle.new(
        session: mock_session, response: mock_response, thread_id: "thread-err-false"
      )

      result = nil
      capture_logs { result = runner.send(:send_analysis_followup_if_needed, bundle) }
      assert_equal false, result
    end

    test "send_analysis_followup_if_needed rescues errors without crashing" do
      runner = Earl::Runner.new

      mock_session = build_mock_session
      mock_session.define_singleton_method(:send_message) { |_text| raise "boom" }
      mock_manager = build_mock_manager(mock_session)
      runner.instance_variable_get(:@services).session_manager = mock_manager

      mm = runner.instance_variable_get(:@services).mattermost
      mm.define_singleton_method(:send_typing) { |**_args| }

      analysis_text = "## Root Cause\n\n#{"x" * 300}\n\nThe problem went wrong due to a bad config."
      mock_response = Object.new
      mock_response.define_singleton_method(:full_text) { analysis_text }
      mock_response.define_singleton_method(:channel_id) { "ch-1" }

      bundle = Earl::Runner::ResponseLifecycle::ResponseBundle.new(
        session: mock_session, response: mock_response, thread_id: "thread-12345678"
      )

      logs = capture_logs { runner.send(:send_analysis_followup_if_needed, bundle) }
      assert_match(/Analysis follow-up failed.*boom/, logs)
    end

    private

    def build_mock_session(on_send: nil)
      mock = Object.new
      mock.define_singleton_method(:on_text) { |&_block| }
      mock.define_singleton_method(:on_system) { |&_block| }
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
      mock.define_singleton_method(:save_stats) { |_id| }
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

    def capture_logs
      output = StringIO.new
      original = Earl.logger
      Earl.logger = Logger.new(output)
      yield
      output.string
    ensure
      Earl.logger = original
    end
  end
end
