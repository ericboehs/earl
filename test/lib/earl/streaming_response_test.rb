# frozen_string_literal: true

require "test_helper"

module Earl
  class StreamingResponseTest < Minitest::Test
    setup do
      Earl.logger = Logger.new(File::NULL)

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
    end

    def build_mock_mattermost
      mock_mm = Object.new
      stub_singleton(mock_mm, :send_typing) { |**_args| }
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) { |**_args| }
      mock_mm
    end

    test "start_typing creates a thread that sends typing indicators" do
      typing_calls = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :send_typing) { |**args| typing_calls << args }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      response.start_typing

      sleep 0.1
      assert typing_calls.any?

      # Clean up
      response.on_complete
    end

    test "start_typing rescues errors and exits thread" do
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :send_typing) { |**_args| raise "connection lost" }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      response.start_typing

      sleep 0.1
      # The typing thread should have exited due to the rescue/break
      typing_thread = response.instance_variable_get(:@post_state).typing_thread
      assert_not typing_thread&.alive?
    end

    test "on_text creates initial post on first call" do
      created_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |channel_id:, message:, root_id:|
        created_posts << { channel_id: channel_id, message: message, root_id: root_id }
        { "id" => "reply-post-1" }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      response.on_text("Hello from Claude")

      assert_equal 1, created_posts.size
      assert_equal "Hello from Claude", created_posts.first[:message]
      assert_equal "thread-123", created_posts.first[:root_id]
    end

    test "on_text updates post after debounce window" do
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # First chunk creates post
      response.on_text("Part 1")

      # Wait for debounce window to pass
      sleep 0.05

      # Second chunk should update immediately with accumulated text
      response.on_text("Part 2")

      assert(updated_posts.any? { |u| u[:message] == "Part 1\n\nPart 2" })
    end

    test "on_text schedules debounce timer for rapid updates" do
      update_count = 0
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        update_count += 1
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # First chunk creates post
      response.on_text("Part 1")

      # Rapid second chunk — schedules debounce timer
      response.on_text("Part 2")

      # Rapid third chunk — timer already scheduled, should NOT create another
      response.on_text("Part 3")

      # Wait for single debounce timer to fire
      sleep 0.05

      # Only one debounced update should have fired
      assert_equal 1, update_count
    end

    test "on_complete removes last text from streamed post and creates final post" do
      updated_posts = []
      created_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**args|
        created_posts << args
        { "id" => "reply-1" }
      end
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      response.on_text("First part")
      sleep 0.05
      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } })
      sleep 0.05
      response.on_text("Final answer")

      updated_posts.clear
      response.on_complete(stats_line: "1,500 tokens")

      # Streamed post updated to remove "Final answer", keeping only tool use
      assert(updated_posts.any? { |u| !u[:message].include?("Final answer") })

      # Final post created with answer text (no stats footer)
      final_post = created_posts.last
      assert_includes final_post[:message], "Final answer"
      assert_not_includes final_post[:message], "tokens"
      assert_not_includes final_post[:message], "Bash"
    end

    test "on_complete edits existing post for simple text-only response" do
      updated_posts = []
      created_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**args|
        created_posts << args
        { "id" => "reply-1" }
      end
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      response.on_text("Simple answer")

      created_posts.clear
      updated_posts.clear
      response.on_complete(stats_line: "500 tokens")

      # No new post created — just edits the existing one
      assert_empty created_posts

      # Existing post updated (no stats footer)
      assert_equal 1, updated_posts.size
      assert_includes updated_posts.first[:message], "Simple answer"
      assert_not_includes updated_posts.first[:message], "tokens"
    end

    test "on_complete without prior text does not update or create posts" do
      updated_posts = []
      created_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end
      stub_singleton(mock_mm, :create_post) do |**args|
        created_posts << args
        { "id" => "reply-1" }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      response.on_complete

      assert_empty updated_posts
      assert_empty created_posts
    end

    test "stop_typing kills the typing thread" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      response.start_typing

      typing_thread = response.instance_variable_get(:@post_state).typing_thread
      assert typing_thread.alive?

      response.on_text("Hello") # on_text calls stop_typing internally

      sleep 0.05
      assert_not typing_thread.alive?
    end

    test "on_text handles errors gracefully" do
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| raise "API error" }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      assert_nothing_raised { response.on_text("Hello") }
    end

    test "on_text stops retrying when create_post returns no id" do
      create_count = 0
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**_args|
        create_count += 1
        {} # No "id" key — simulates API error response
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # First call should attempt create_post and set failure flag
      response.on_text("Part 1")
      assert_equal 1, create_count

      # Second call should NOT retry create_post
      response.on_text("Part 2")
      assert_equal 1, create_count
    end

    test "on_complete handles errors gracefully" do
      call_count = 0
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**_args|
        call_count += 1
        raise "network error" if call_count > 1

        { "id" => "reply-1" }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      response.on_text("Some text")

      assert_nothing_raised { response.on_complete }
    end

    test "on_text accumulates across multiple calls" do
      created_posts = []
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |channel_id:, message:, root_id:|
        created_posts << { message: message }
        { "id" => "reply-1" }
      end
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      response.on_text("First chunk")
      assert_equal "First chunk", created_posts.first[:message]

      sleep 0.05
      response.on_text("Second chunk")

      assert(updated_posts.any? { |u| u[:message] == "First chunk\n\nSecond chunk" })
    end

    test "on_tool_use appends formatted indicator" do
      created_posts = []
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |channel_id:, message:, root_id:|
        created_posts << { message: message }
        { "id" => "reply-1" }
      end
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      response.on_text("Let me check that.")
      sleep 0.05

      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls -la" } })

      expected = "Let me check that.\n\n🔧 `Bash`\n```\nls -la\n```"
      assert(updated_posts.any? { |u| u[:message] == expected })
    end

    test "on_tool_use creates initial post when no text precedes" do
      created_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |channel_id:, message:, root_id:|
        created_posts << { message: message }
        { "id" => "reply-1" }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      response.on_tool_use({ id: "tu-1", name: "Read", input: { "file_path" => "/tmp/foo.rb" } })

      assert_equal 1, created_posts.size
      assert_includes created_posts.first[:message], "📖 `Read`"
      assert_includes created_posts.first[:message], "/tmp/foo.rb"
    end

    test "full flow: text then tool then text holds back text after tools" do
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      response.on_text("Checking your directory.")
      sleep 0.05
      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls ~" } })
      sleep 0.05
      response.on_text("Here are the results.")

      final = updated_posts.last[:message]
      assert_includes final, "Checking your directory."
      assert_includes final, "🔧 `Bash`"
      assert_includes final, "ls ~"
      refute_includes final, "Here are the results."
    end

    test "format_tool_use uses correct icons" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      {
        "Bash" => "🔧", "Read" => "📖", "WebFetch" => "🌐", "WebSearch" => "🌐",
        "Edit" => "✏️", "Write" => "📝", "Glob" => "🔍", "Grep" => "🔍"
      }.each do |tool_name, icon|
        result = response.send(:format_tool_use, { name: tool_name, input: {} })
        assert result.start_with?(icon), "Expected #{tool_name} to use icon #{icon}, got: #{result}"
      end
    end

    test "format_tool_use falls back to JSON for unknown tools" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      result = response.send(:format_tool_use, { name: "CustomTool", input: { "foo" => "bar" } })

      assert_includes result, "⚙️"
      assert_includes result, "`CustomTool`"
      assert_includes result, '"foo":"bar"'
    end

    test "on_tool_use skips update when create_failed" do
      create_count = 0
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**_args|
        create_count += 1
        {} # No "id" key — simulates failure
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # First text call fails to create post
      response.on_text("Part 1")
      assert_equal 1, create_count

      # Tool use should also skip since create_failed
      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } })
      assert_equal 1, create_count
    end

    test "format_tool_use returns name only for unknown tool with empty input" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      result = response.send(:format_tool_use, { name: "CustomTool", input: {} })
      assert_equal "⚙️ `CustomTool`", result
      assert_not_includes result, "```"
    end

    test "format_tool_use handles nil input values for unknown tool" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      result = response.send(:format_tool_use, { name: "CustomTool", input: { "key" => nil } })
      assert_equal "⚙️ `CustomTool`", result
    end

    test "on_complete with only tool segments and no text" do
      created_posts = []
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**args|
        created_posts << args
        { "id" => "reply-1" }
      end
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Only tool use, no text segments
      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } })
      sleep 0.05
      response.on_tool_use({ id: "tu-2", name: "Read", input: { "file_path" => "/tmp/foo" } })

      created_posts.clear
      updated_posts.clear
      response.on_complete(stats_line: "100 tokens")

      # All segments are tools, so last_text_index is nil -> remove_last_text returns early
      # Then creates notification post with full_text (which is all tools) + stats
      assert created_posts.any?
    end

    test "on_complete multi-segment removes text leaving tool-only content" do
      created_posts = []
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**args|
        created_posts << args
        { "id" => "reply-1" }
      end
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Single text segment followed by tool
      response.on_text("Only text here")
      sleep 0.05
      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } })

      created_posts.clear
      updated_posts.clear
      response.on_complete(stats_line: "50 tokens")

      # After removing "Only text here", only tool segment remains
      # update_post should be called for the tool-only content (non-empty after removal)
      assert updated_posts.any?
    end

    test "on_complete multi-segment with single text leaves empty after removal" do
      created_posts = []
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**args|
        created_posts << args
        { "id" => "reply-1" }
      end
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Tool then text — removing text leaves only tool, which is empty-ish in text terms
      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } })
      sleep 0.05
      response.on_text("Answer here")

      created_posts.clear
      updated_posts.clear
      response.on_complete(stats_line: "200 tokens")

      # After removing "Answer here", only tool segment remains
      # The streamed post should be updated with just the tool content
      # A new notification post should be created with the answer + stats
      assert(created_posts.any? { |p| p[:message].include?("Answer here") })
    end

    test "remove_trailing_text keeps tool segments in streamed post" do
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**_args|
        { "id" => "reply-1" }
      end
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Simulate tool-only post with trailing text to remove
      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "echo hi" } })

      segments = response.instance_variable_get(:@segments)
      segments << "Trailing text"

      updated_posts.clear
      response.send(:remove_trailing_text_from_streamed_post)

      # Tool segment remains, trailing text removed
      assert_equal 1, updated_posts.size
      assert_includes updated_posts.first[:message], "🔧 `Bash`"
      refute_includes updated_posts.first[:message], "Trailing text"
    end

    test "on_complete multi-segment with create_failed has no reply_post_id" do
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| {} } # No id — failure
      stub_singleton(mock_mm, :update_post) { |**_args| }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Text then tool — creates a multi-segment response, but post creation fails
      response.on_text("Some text")
      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "echo" } })

      # Finalize with no reply_post_id — remove_last_text should return early at L150
      assert_nothing_raised { response.on_complete(stats_line: "50 tokens") }
    end

    test "on_tool_use handles errors gracefully" do
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| raise "API error" }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      assert_nothing_raised { response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } }) }
    end

    test "channel_id returns context channel_id" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-99")
      assert_equal "ch-99", response.channel_id
    end

    test "full_text returns accumulated text after on_text calls" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      assert_equal "", response.full_text

      response.on_text("First chunk")
      assert_equal "First chunk", response.full_text

      sleep 0.05
      response.on_text("Second chunk")
      assert_equal "First chunk\n\nSecond chunk", response.full_text
    end

    test "on_complete with text-only but no reply_post_id due to create_failed" do
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| {} } # No id — failure

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      response.on_text("Some text")
      # create_failed is true, reply_post_id is nil

      # finalize should handle the case: full_text is not empty but reply_post_id is nil
      assert_nothing_raised { response.on_complete }
    end

    test "on_text handles error with nil backtrace" do
      mock_mm = build_mock_mattermost
      error = StandardError.new("nil trace")
      stub_singleton(mock_mm, :create_post) { |**_args| raise error }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      assert_nothing_raised { response.on_text("Hello") }
    end

    test "on_tool_use handles error with nil backtrace" do
      mock_mm = build_mock_mattermost
      error = StandardError.new("nil trace")
      stub_singleton(mock_mm, :create_post) { |**_args| raise error }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      assert_nothing_raised { response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } }) }
    end

    test "on_complete handles error with nil backtrace" do
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) { |**_args| raise StandardError, "nil trace" }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      response.on_text("text")
      assert_nothing_raised { response.on_complete }
    end

    test "on_text handles error with non-nil backtrace" do
      mock_mm = build_mock_mattermost
      error = StandardError.new("real trace")
      error.set_backtrace(%w[line1 line2 line3])
      stub_singleton(mock_mm, :create_post) { |**_args| raise error }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      assert_nothing_raised { response.on_text("Hello") }
    end

    test "on_tool_use handles error with non-nil backtrace" do
      mock_mm = build_mock_mattermost
      error = StandardError.new("real trace")
      error.set_backtrace(%w[line1 line2 line3])
      stub_singleton(mock_mm, :create_post) { |**_args| raise error }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      assert_nothing_raised { response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } }) }
    end

    test "on_complete handles error with non-nil backtrace" do
      mock_mm = build_mock_mattermost
      error = StandardError.new("real trace")
      error.set_backtrace(%w[line1 line2 line3])
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) { |**_args| raise error }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      response.on_text("text")
      assert_nothing_raised { response.on_complete }
    end

    test "finalize_empty returns true when text empty and no post_id" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      ps = response.instance_variable_get(:@post_state)
      result = response.send(:finalize_empty?, ps)
      assert result, "Expected finalize_empty? to be true for empty text and no post_id"
    end

    test "finalize joins active debounce timer" do
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # First chunk creates the post
      response.on_text("Part 1")

      # Rapid second chunk schedules debounce timer (within DEBOUNCE_MS window)
      response.on_text("Part 2")

      # Verify debounce timer is active
      ps = response.instance_variable_get(:@post_state)
      assert ps.debounce_timer, "Expected debounce timer to be set"

      # Call on_complete immediately — finalize should join the active timer
      response.on_complete

      # Timer should have been joined and completed
      refute ps.debounce_timer&.alive?, "Expected debounce timer to have completed"
    end

    test "remove_trailing_text returns early when no tool segments" do
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      response.on_text("Just text, no tools")

      updated_posts.clear
      response.send(:remove_trailing_text_from_streamed_post)

      # No tool segments means last_tool_index is nil, so returns early
      assert_empty updated_posts
    end

    test "on_tool_use skips AskUserQuestion" do
      created_posts = []
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) do |**_args|
        created_posts << true
        { "id" => "reply-1" }
      end
      stub_singleton(mock_mm, :update_post) do |**_args|
        updated_posts << true
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      response.on_tool_use({ id: "tu-1", name: "AskUserQuestion", input: { "questions" => [] } })

      assert_empty created_posts
      assert_empty updated_posts
    end

    # --- on_text_with_images tests ---

    test "on_text_with_images logs and stores image refs" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
        source: :file_path, data: "/tmp/test.png", media_type: "image/png", filename: "test.png"
      )
      response.on_text_with_images("Check this image", [ref])

      image_refs = response.instance_variable_get(:@post_state).image_refs
      assert_equal 1, image_refs.size
      assert_equal "test.png", image_refs.first.filename
    end

    test "on_text_with_images skips log when refs empty" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      response.on_text_with_images("No images here", [])

      image_refs = response.instance_variable_get(:@post_state).image_refs
      assert_empty image_refs
    end

    test "on_text_with_images rescues errors and logs" do
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| raise "boom" }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
        source: :file_path, data: "/tmp/test.png", media_type: "image/png", filename: "test.png"
      )
      assert_nothing_raised { response.on_text_with_images("text", [ref]) }
    end

    test "on_text_with_images handles error with non-nil backtrace" do
      mock_mm = build_mock_mattermost
      error = StandardError.new("traced")
      error.set_backtrace(%w[line1 line2])
      stub_singleton(mock_mm, :create_post) { |**_args| raise error }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
        source: :file_path, data: "/tmp/test.png", media_type: "image/png", filename: "test.png"
      )
      assert_nothing_raised { response.on_text_with_images("text", [ref]) }
    end

    # --- add_image_refs tests ---

    test "add_image_refs appends refs to post state" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
        source: :base64, data: "abc123", media_type: "image/png", filename: "img.png"
      )
      response.add_image_refs([ref])

      image_refs = response.instance_variable_get(:@post_state).image_refs
      assert_equal 1, image_refs.size
    end

    test "add_image_refs rescues errors" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Force an error by passing something that will blow up in concat
      assert_nothing_raised { response.add_image_refs(nil) }
    end

    # --- ImageAttachment module tests ---

    test "upload_collected_images skips when no refs" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # No refs, so should return early
      assert_nothing_raised { response.send(:upload_collected_images) }
    end

    test "upload_collected_images uploads refs and posts file attachments" do
      uploaded_files = []
      file_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :upload_file) do |upload|
        uploaded_files << upload
        { "file_infos" => [{ "id" => "file-#{uploaded_files.size}" }] }
      end
      stub_singleton(mock_mm, :create_post_with_files) do |file_post|
        file_posts << file_post
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Create a temp file to read
      require "tempfile"
      tmp = Tempfile.new(["test", ".png"])
      tmp.write("fake png data")
      tmp.close

      ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
        source: :file_path, data: tmp.path, media_type: "image/png", filename: "test.png"
      )
      response.instance_variable_get(:@post_state).image_refs.push(ref)

      response.send(:upload_collected_images)

      assert_equal 1, uploaded_files.size
      assert_equal 1, file_posts.size
    ensure
      tmp&.unlink
    end

    # --- Error rescue branch tests (nil backtrace paths) ---

    test "on_text rescues errors with nil backtrace" do
      mock_mm = build_mock_mattermost
      error = StandardError.new("sync fail")
      stub_singleton(mock_mm, :create_post) { |**_args| raise error }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      assert_nothing_raised { response.on_text("hello") }
    end

    test "on_text rescues errors with non-nil backtrace" do
      mock_mm = build_mock_mattermost
      error = StandardError.new("sync fail")
      error.set_backtrace(%w[line1 line2 line3])
      stub_singleton(mock_mm, :create_post) { |**_args| raise error }

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
      assert_nothing_raised { response.on_text("hello") }
    end

    test "on_tool_use rescues errors with nil backtrace" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Force handle_tool_use_display to blow up by passing bad tool_use
      stub_singleton(response, :handle_tool_use_display) { |_tu| raise StandardError, "tool fail" }
      assert_nothing_raised { response.on_tool_use({ name: "Bash", input: {} }) }
    end

    test "on_tool_use rescues errors with non-nil backtrace" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      error = StandardError.new("tool fail")
      error.set_backtrace(%w[frame1 frame2])
      stub_singleton(response, :handle_tool_use_display) { |_tu| raise error }
      assert_nothing_raised { response.on_tool_use({ name: "Bash", input: {} }) }
    end

    test "on_complete rescues errors with nil backtrace" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      stub_singleton(response, :finalize) { raise StandardError, "finalize fail" }
      assert_nothing_raised { response.on_complete }
    end

    test "on_complete rescues errors with non-nil backtrace" do
      mock_mm = build_mock_mattermost
      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      error = StandardError.new("finalize fail")
      error.set_backtrace(%w[frame1 frame2])
      stub_singleton(response, :finalize) { raise error }
      assert_nothing_raised { response.on_complete }
    end

    test "remove_trailing_text_from_streamed_post updates when full_text not empty" do
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Create a posted response with tool + text segments
      response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "echo hi" } })
      sleep 0.05
      response.on_text("Some trailing text after tool")

      updated_posts.clear
      response.send(:remove_trailing_text_from_streamed_post)

      # Should have updated the post with tool-only content (non-empty)
      assert updated_posts.any?, "Expected update_post to be called"
      assert_includes updated_posts.first[:message], "Bash"
      refute_includes updated_posts.first[:message], "trailing text"
    end

    test "remove_trailing_text_from_streamed_post skips update when full_text becomes empty" do
      updated_posts = []
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) do |post_id:, message:|
        updated_posts << { post_id: post_id, message: message }
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Simulate a posted response with only text segments (no tool segments at all)
      response.on_text("first chunk")
      sleep 0.05

      updated_posts.clear
      # Manually call remove_trailing_text — since there are no tool segments,
      # last_tool_index will be nil, and no filtering occurs
      response.send(:remove_trailing_text_from_streamed_post)

      # No update should have been triggered since no tool segments found
      assert_empty updated_posts
    end

    test "upload_collected_images skips posting when all uploads fail" do
      mock_mm = build_mock_mattermost
      stub_singleton(mock_mm, :create_post) { |**_args| { "id" => "reply-1" } }
      stub_singleton(mock_mm, :update_post) { |**_args| }
      created_file_posts = []
      stub_singleton(mock_mm, :upload_file) { |_upload| { "file_infos" => [] } }
      stub_singleton(mock_mm, :create_post_with_files) do |file_post|
        created_file_posts << file_post
      end

      response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

      # Post some text first
      response.on_text("hello")
      sleep 0.05

      # Add image refs that will all fail to upload (upload returns empty file_infos)
      ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
        source: :file_path, data: "/nonexistent/image.png", media_type: "image/png", filename: "image.png"
      )
      response.add_image_refs([ref])

      # Finalize should attempt upload but get nil file_ids, skip posting
      response.on_complete
      sleep 0.05

      assert_empty created_file_posts
    end
  end
end
