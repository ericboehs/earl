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

    # Second chunk should update immediately
    response.on_text("Part 1 Part 2")

    assert updated_posts.any? { |u| u[:message] == "Part 1 Part 2" }
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
    response.on_text("Part 1 Part 2")

    # Rapid third chunk — timer already scheduled, should NOT create another
    response.on_text("Part 1 Part 2 Part 3")

    # Wait for single debounce timer to fire
    sleep 0.5

    # Only one debounced update should have fired
    assert_equal 1, update_count
  end

  test "on_complete does final update" do
    updated_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")

    response.on_text("Final text")
    response.on_complete

    final = updated_posts.last
    assert_equal "Final text", final[:message]
  end

  test "on_complete without prior text does not update post" do
    updated_posts = []
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:update_post) do |post_id:, message:|
      updated_posts << { post_id: post_id, message: message }
    end

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
    response.on_complete

    assert_empty updated_posts
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
    mock_mm = build_mock_mattermost
    mock_mm.define_singleton_method(:create_post) { |**_args| { "id" => "reply-1" } }
    mock_mm.define_singleton_method(:update_post) { |**_args| raise "network error" }

    response = Earl::StreamingResponse.new(thread_id: "thread-123", mattermost: mock_mm, channel_id: "ch-1")
    response.on_text("Some text")

    assert_nothing_raised { response.on_complete }
  end
end
