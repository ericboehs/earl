require "test_helper"

class Earl::Mcp::ApprovalHandlerTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)
  end

  teardown do
    Earl.logger = nil
  end

  test "returns allow when auto-approve is active" do
    handler = build_handler
    # Set allow_all directly
    handler.instance_variable_set(:@allow_all, true)

    result = handler.handle(tool_name: "Bash", input: { "command" => "ls" })

    assert_equal "allow", result[:behavior]
  end

  test "denies when post creation fails" do
    handler = build_handler(post_success: false)

    result = handler.handle(tool_name: "Bash", input: { "command" => "ls" })

    assert_equal "deny", result[:behavior]
  end

  test "format_input returns command for Bash tool" do
    handler = build_handler
    result = handler.send(:format_input, "Bash", { "command" => "ls -la /tmp" })

    assert_equal "ls -la /tmp", result
  end

  test "format_input returns file_path for Edit tool" do
    handler = build_handler
    result = handler.send(:format_input, "Edit", {
      "file_path" => "/tmp/foo.rb",
      "new_string" => "new content"
    })

    assert_includes result, "/tmp/foo.rb"
    assert_includes result, "new content"
  end

  test "format_input returns file_path for Write tool" do
    handler = build_handler
    result = handler.send(:format_input, "Write", {
      "file_path" => "/tmp/bar.rb",
      "content" => "file content"
    })

    assert_includes result, "/tmp/bar.rb"
    assert_includes result, "file content"
  end

  test "format_input returns JSON for unknown tool" do
    handler = build_handler
    result = handler.send(:format_input, "Unknown", { "key" => "value" })

    assert_includes result, "key"
    assert_includes result, "value"
  end

  test "process_reaction allows for +1 emoji" do
    handler = build_handler
    result = handler.send(:process_reaction, "+1")

    assert_equal "allow", result[:behavior]
  end

  test "process_reaction allows and sets allow_all for white_check_mark" do
    handler = build_handler
    result = handler.send(:process_reaction, "white_check_mark")

    assert_equal "allow", result[:behavior]
    assert handler.instance_variable_get(:@allow_all)
  end

  test "process_reaction denies for -1 emoji" do
    handler = build_handler
    result = handler.send(:process_reaction, "-1")

    assert_equal "deny", result[:behavior]
  end

  test "process_reaction returns nil for unknown emoji" do
    handler = build_handler
    result = handler.send(:process_reaction, "smile")

    assert_nil result
  end

  test "handle with auto-approve skips posting" do
    handler = build_handler
    handler.instance_variable_set(:@allow_all, true)

    result = handler.handle(tool_name: "Read", input: { "path" => "/tmp" })
    assert_equal "allow", result[:behavior]
    assert_nil result[:updatedInput]
  end

  test "post_permission_request formats message with tool_name" do
    posts = []
    handler = build_handler_with_tracking(posts: posts)

    post_id = handler.send(:post_permission_request, "Bash", { "command" => "echo hello" })

    assert_equal "perm-post-1", post_id
    assert_equal 1, posts.size
    assert_includes posts.first[:body][:message], "Bash"
    assert_includes posts.first[:body][:message], "echo hello"
  end

  test "add_reaction_options adds all three emojis" do
    config = build_mock_config
    posts = []

    api = Object.new
    psts = posts
    api.define_singleton_method(:post) do |path, body|
      psts << { path: path, body: body }
      response = Object.new
      response.define_singleton_method(:body) { JSON.generate({ "id" => "perm-post-1" }) }
      response.define_singleton_method(:is_a?) do |klass|
        klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
      end
      response
    end
    api.define_singleton_method(:put) { |*_args| Object.new }
    api.define_singleton_method(:get) { |*_args| Object.new }

    handler = Earl::Mcp::ApprovalHandler.new(config: config, api_client: api)
    handler.send(:add_reaction_options, "post-1")

    reaction_posts = posts.select { |p| p[:path] == "/reactions" }
    assert_equal 3, reaction_posts.size
    assert_equal %w[+1 white_check_mark -1], reaction_posts.map { |r| r[:body][:emoji_name] }
  end

  test "delete_permission_post calls delete on api" do
    deletes = []
    handler = build_handler_with_tracking(deletes: deletes)

    handler.send(:delete_permission_post, "post-1")

    assert_equal 1, deletes.size
    assert_equal "/posts/post-1", deletes.first[:path]
  end

  test "delete_permission_post handles errors gracefully" do
    handler = build_handler
    api = handler.instance_variable_get(:@api)
    api.define_singleton_method(:delete) { |_path| raise "network error" }

    assert_nothing_raised { handler.send(:delete_permission_post, "post-1") }
  end

  test "allowed_reactor? returns true when allowed_users is empty" do
    handler = build_handler
    # Mock allowed_users to be empty
    handler.instance_variable_get(:@config).define_singleton_method(:allowed_users) { [] }

    assert handler.send(:allowed_reactor?, "any-user-id")
  end

  private

  def build_handler(post_success: true)
    config = build_mock_config
    api = build_mock_api(post_success: post_success)
    Earl::Mcp::ApprovalHandler.new(config: config, api_client: api)
  end

  def build_mock_config
    config = Object.new
    config.define_singleton_method(:platform_channel_id) { "channel-1" }
    config.define_singleton_method(:platform_thread_id) { "thread-1" }
    config.define_singleton_method(:platform_bot_id) { "bot-1" }
    config.define_singleton_method(:allowed_users) { [] }
    config.define_singleton_method(:permission_timeout_ms) { 1000 }
    config.define_singleton_method(:platform_url) { "http://localhost:8065" }
    config.define_singleton_method(:platform_token) { "test-token" }
    config.define_singleton_method(:websocket_url) { "ws://localhost:8065/api/v4/websocket" }
    config
  end

  def build_mock_api(post_success: true)
    api = Object.new

    if post_success
      api.define_singleton_method(:post) do |path, body|
        response = Object.new
        response.define_singleton_method(:body) { JSON.generate({ "id" => "perm-post-1" }) }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end
    else
      api.define_singleton_method(:post) do |path, body|
        response = Object.new
        response.define_singleton_method(:body) { '{"error":"fail"}' }
        response.define_singleton_method(:code) { "500" }
        response.define_singleton_method(:is_a?) do |klass|
          Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end
    end

    api.define_singleton_method(:put) do |path, body|
      Object.new
    end

    api.define_singleton_method(:delete) do |path|
      Object.new
    end

    api.define_singleton_method(:get) do |path|
      response = Object.new
      response.define_singleton_method(:body) { JSON.generate({ "id" => "user-1", "username" => "alice" }) }
      response.define_singleton_method(:is_a?) do |klass|
        klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
      end
      response
    end

    api
  end

  def build_handler_with_tracking(posts: [], reactions: [], puts_data: [], deletes: [])
    config = build_mock_config

    api = Object.new
    psts = posts
    rxns = reactions
    pts = puts_data
    dels = deletes

    api.define_singleton_method(:post) do |path, body|
      psts << { path: path, body: body }
      response = Object.new
      response.define_singleton_method(:body) { JSON.generate({ "id" => "perm-post-1" }) }
      response.define_singleton_method(:is_a?) do |klass|
        klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
      end
      response
    end

    api.define_singleton_method(:put) do |path, body|
      pts << { path: path, body: body }
      Object.new
    end

    api.define_singleton_method(:delete) do |path|
      dels << { path: path }
      Object.new
    end

    api.define_singleton_method(:get) do |path|
      response = Object.new
      response.define_singleton_method(:body) { JSON.generate({ "id" => "user-1", "username" => "alice" }) }
      response.define_singleton_method(:is_a?) do |klass|
        klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
      end
      response
    end

    Earl::Mcp::ApprovalHandler.new(config: config, api_client: api)
  end
end
