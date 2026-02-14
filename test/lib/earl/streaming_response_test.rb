require "test_helper"

class Earl::StreamingResponseTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)
  end

  teardown do
    Earl.logger = nil
  end

  def build_mock_mattermost
    mock_mm = Object.new
    mock_mm.define_singleton_method(:send_typing) { |**_args| }
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) { |**_args| }
    mock_mm
  end

  test "start_typing creates a thread that sends typing indicators" do
    typing_calls = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:send_typing) { |**args| typing_calls << args }

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
    response.start_typing

    sleep 0.1
    assert typing_calls.any?

    # Clean up
    response.on_complete
  end

  test "start_typing rescues errors and exits thread" do
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:send_typing) { |**_args| raise "connection lost" }

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
    response.start_typing

    sleep 0.1
    # The typing thread should have exited due to the rescue/break
    typing_thread = response.instance_variable_get(:@typing_thread)
    assert_not typing_thread&.alive?
  end

  test "on_text creates initial post on first call" do
    created_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
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
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    # First chunk creates post
    response.on_text("Part 1")

    # Wait for debounce window to pass
    sleep 0.35

    # Second chunk should update immediately with accumulated text
    response.on_text("Part 2")

    assert updated_posts.any? { |u| u[:message] == "Part 1\n\nPart 2" }
  end

  test "on_text schedules debounce timer for rapid updates" do
    update_count = 0
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
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
    sleep 0.5

    # Only one debounced update should have fired
    assert_equal 1, update_count
  end

  test "on_complete removes last text from streamed post and creates final post" do
    updated_posts = []
    created_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) do |**args|
      created_posts << args
      { "id" => "reply-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    response.on_text("First part")
    sleep 0.35
    response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } })
    sleep 0.35
    response.on_text("Final answer")

    updated_posts.clear
    response.on_complete(stats_line: "1,500 tokens")

    # Streamed post updated to remove "Final answer", keeping only tool use
    assert updated_posts.any? { |u| !u[:message].include?("Final answer") }

    # Final post created with answer text + stats footer
    final_post = created_posts.last
    assert_includes final_post[:message], "Final answer"
    assert_includes final_post[:message], "1,500 tokens"
    assert_not_includes final_post[:message], "Bash"
  end

  test "on_complete edits existing post for simple text-only response" do
    updated_posts = []
    created_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) do |**args|
      created_posts << args
      { "id" => "reply-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    response.on_text("Simple answer")

    created_posts.clear
    updated_posts.clear
    response.on_complete(stats_line: "500 tokens")

    # No new post created — just edits the existing one
    assert_empty created_posts

    # Existing post updated with stats footer
    assert_equal 1, updated_posts.size
    assert_includes updated_posts.first[:message], "Simple answer"
    assert_includes updated_posts.first[:message], "500 tokens"
  end

  test "on_complete without prior text does not update or create posts" do
    updated_posts = []
    created_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end
    mock_mm.define_singleton_method(:create_post) do |**args|
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

    typing_thread = response.instance_variable_get(:@typing_thread)
    assert typing_thread.alive?

    response.on_text("Hello") # on_text calls stop_typing internally

    sleep 0.05
    assert_not typing_thread.alive?
  end

  test "on_text handles errors gracefully" do
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) { |**_args| raise "API error" }

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    assert_nothing_raised { response.on_text("Hello") }
  end

  test "on_text stops retrying when create_post returns no id" do
    create_count = 0
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) do |**_args|
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
    mock_mm.define_singleton_method(:create_post) do |**_args|
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
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      created_posts << { message: message }
      { "id" => "reply-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    response.on_text("First chunk")
    assert_equal "First chunk", created_posts.first[:message]

    sleep 0.35
    response.on_text("Second chunk")

    assert updated_posts.any? { |u| u[:message] == "First chunk\n\nSecond chunk" }
  end

  test "on_tool_use appends formatted indicator" do
    created_posts = []
    updated_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      created_posts << { message: message }
      { "id" => "reply-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    response.on_text("Let me check that.")
    sleep 0.35

    response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls -la" } })

    expected = "Let me check that.\n\n🔧 `Bash`\n```\nls -la\n```"
    assert updated_posts.any? { |u| u[:message] == expected }
  end

  test "on_tool_use creates initial post when no text precedes" do
    created_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      created_posts << { message: message }
      { "id" => "reply-1" }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    response.on_tool_use({ id: "tu-1", name: "Read", input: { "file_path" => "/tmp/foo.rb" } })

    assert_equal 1, created_posts.size
    assert_includes created_posts.first[:message], "📖 `Read`"
    assert_includes created_posts.first[:message], "/tmp/foo.rb"
  end

  test "full flow: text then tool then text accumulates correctly" do
    updated_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    response.on_text("Checking your directory.")
    sleep 0.35
    response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls ~" } })
    sleep 0.35
    response.on_text("Here are the results.")

    final = updated_posts.last[:message]
    assert_includes final, "Checking your directory."
    assert_includes final, "🔧 `Bash`"
    assert_includes final, "ls ~"
    assert_includes final, "Here are the results."
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
    mock_mm.define_singleton_method(:create_post) do |**_args|
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
    mock_mm.define_singleton_method(:create_post) do |**args|
      created_posts << args
      { "id" => "reply-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    # Only tool use, no text segments
    response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } })
    sleep 0.35
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
    mock_mm.define_singleton_method(:create_post) do |**args|
      created_posts << args
      { "id" => "reply-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    # Single text segment followed by tool
    response.on_text("Only text here")
    sleep 0.35
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
    mock_mm.define_singleton_method(:create_post) do |**args|
      created_posts << args
      { "id" => "reply-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    # Tool then text — removing text leaves only tool, which is empty-ish in text terms
    response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } })
    sleep 0.35
    response.on_text("Answer here")

    created_posts.clear
    updated_posts.clear
    response.on_complete(stats_line: "200 tokens")

    # After removing "Answer here", only tool segment remains
    # The streamed post should be updated with just the tool content
    # A new notification post should be created with the answer + stats
    assert created_posts.any? { |p| p[:message].include?("Answer here") }
  end

  test "remove_last_text skips update_post when result is empty" do
    created_posts = []
    updated_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) do |**args|
      created_posts << args
      { "id" => "reply-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    # Only a single text segment (no tool segments)
    response.on_text("Only text here")

    # Manually inject a tool-like segment so it's multi-segment but tool check fails
    # Actually, we need a scenario where removing the text leaves segments empty.
    # Single text, then we manually make it look like multi-segment for finalize:
    segments = response.instance_variable_get(:@segments)
    segments.clear
    segments << "Just text"

    # Make full_text match
    post_state = response.instance_variable_get(:@post_state)
    post_state.full_text = "Just text"

    created_posts.clear
    updated_posts.clear

    # Directly call remove_last_text_from_streamed_post
    response.send(:remove_last_text_from_streamed_post)

    # After removing the only text segment, full_text is empty
    # So update_post should NOT be called (the else branch of L157)
    assert_empty updated_posts
    assert_equal "", post_state.full_text
  end

  test "on_complete multi-segment with create_failed has no reply_post_id" do
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) { |**_args| {} } # No id — failure
    mock_mm.define_singleton_method(:update_post) { |**_args| }

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    # Text then tool — creates a multi-segment response, but post creation fails
    response.on_text("Some text")
    response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "echo" } })

    # Finalize with no reply_post_id — remove_last_text should return early at L150
    assert_nothing_raised { response.on_complete(stats_line: "50 tokens") }
  end

  test "on_tool_use handles errors gracefully" do
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) { |**_args| raise "API error" }

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    assert_nothing_raised { response.on_tool_use({ id: "tu-1", name: "Bash", input: { "command" => "ls" } }) }
  end

  test "channel_id returns context channel_id" do
    mock_mm = build_mock_mattermost
    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-99")
    assert_equal "ch-99", response.channel_id
  end

  test "on_complete with text-only but no reply_post_id due to create_failed" do
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) { |**_args| {} } # No id — failure

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    response.on_text("Some text")
    # create_failed is true, reply_post_id is nil

    # finalize should handle the case: full_text is not empty but reply_post_id is nil
    assert_nothing_raised { response.on_complete }
  end

  test "on_tool_use skips AskUserQuestion" do
    created_posts = []
    updated_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) do |**_args|
      created_posts << true
      { "id" => "reply-1" }
    end
    mock_mm.define_singleton_method(:update_post) do |**_args|
      updated_posts << true
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    response.on_tool_use({ id: "tu-1", name: "AskUserQuestion", input: { "questions" => [] } })

    assert_empty created_posts
    assert_empty updated_posts
  end
end
