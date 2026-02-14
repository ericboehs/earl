require "test_helper"

class Earl::Mcp::ApprovalHandlerTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)
    @tmp_dir = Dir.mktmpdir("earl-allowed-tools-test")
    @original_allowed_tools_dir = Earl::Mcp::ApprovalHandler::ALLOWED_TOOLS_DIR
    Earl::Mcp::ApprovalHandler.send(:remove_const, :ALLOWED_TOOLS_DIR)
    Earl::Mcp::ApprovalHandler.const_set(:ALLOWED_TOOLS_DIR, @tmp_dir)
  end

  teardown do
    Earl.logger = nil
    FileUtils.rm_rf(@tmp_dir)
    Earl::Mcp::ApprovalHandler.send(:remove_const, :ALLOWED_TOOLS_DIR)
    Earl::Mcp::ApprovalHandler.const_set(:ALLOWED_TOOLS_DIR, @original_allowed_tools_dir)
  end

  test "returns allow when tool is in allowed_tools set" do
    handler = build_handler
    handler.instance_variable_get(:@allowed_tools).add("Bash")

    result = handler.handle(tool_name: "Bash", input: { "command" => "ls" })

    assert_equal "allow", result[:behavior]
  end

  test "does not auto-approve a different tool when only one is allowed" do
    handler = build_handler
    handler.instance_variable_get(:@allowed_tools).add("Bash")

    # Edit should still require approval — since we can't mock the full flow,
    # we test that handle does NOT return early for a non-allowed tool
    # by verifying it posts a permission request
    posts = []
    handler_with_tracking = build_handler_with_tracking(posts: posts)
    handler_with_tracking.instance_variable_get(:@allowed_tools).add("Bash")

    # This will post a permission request (and then fail on wait_for_reaction)
    # but we just need to verify it doesn't auto-approve
    result = handler_with_tracking.handle(tool_name: "Edit", input: { "file_path" => "/tmp/foo", "new_string" => "x" })

    # It should have posted a permission request for Edit
    permission_posts = posts.select { |p| p[:path] == "/posts" }
    assert permission_posts.any? { |p| p[:body][:message].include?("Edit") }
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

  test "process_reaction allows for +1 emoji without adding to allowed_tools" do
    handler = build_handler
    input = { "command" => "ls" }
    result = handler.send(:process_reaction, "+1", "Bash", input)

    assert_equal "allow", result[:behavior]
    assert_equal input, result[:updatedInput]
    assert_not handler.instance_variable_get(:@allowed_tools).include?("Bash")
  end

  test "process_reaction allows and adds tool to allowed_tools for white_check_mark" do
    handler = build_handler
    input = { "command" => "ls" }
    result = handler.send(:process_reaction, "white_check_mark", "Bash", input)

    assert_equal "allow", result[:behavior]
    assert_equal input, result[:updatedInput]
    assert handler.instance_variable_get(:@allowed_tools).include?("Bash")
  end

  test "process_reaction persists allowed_tools to disk on white_check_mark" do
    handler = build_handler
    handler.send(:process_reaction, "white_check_mark", "Bash", { "command" => "ls" })

    # Verify the file was written
    path = handler.send(:allowed_tools_path)
    assert File.exist?(path)

    saved = JSON.parse(File.read(path))
    assert_includes saved, "Bash"
  end

  test "process_reaction denies for -1 emoji" do
    handler = build_handler
    result = handler.send(:process_reaction, "-1", "Bash", { "command" => "ls" })

    assert_equal "deny", result[:behavior]
  end

  test "process_reaction returns nil for unknown emoji" do
    handler = build_handler
    result = handler.send(:process_reaction, "smile", "Bash", { "command" => "ls" })

    assert_nil result
  end

  test "handle with allowed tool skips posting" do
    handler = build_handler
    handler.instance_variable_get(:@allowed_tools).add("Read")

    input = { "path" => "/tmp" }
    result = handler.handle(tool_name: "Read", input: input)
    assert_equal "allow", result[:behavior]
    assert_equal input, result[:updatedInput]
  end

  test "load_allowed_tools reads from persisted file" do
    # Write a test file
    thread_id = "thread-1"
    path = File.join(@tmp_dir, "#{thread_id}.json")
    File.write(path, JSON.generate(%w[Bash Read]))

    handler = build_handler
    allowed = handler.instance_variable_get(:@allowed_tools)

    assert allowed.include?("Bash")
    assert allowed.include?("Read")
    assert_not allowed.include?("Edit")
  end

  test "load_allowed_tools returns empty set for missing file" do
    handler = build_handler
    allowed = handler.instance_variable_get(:@allowed_tools)
    assert allowed.empty?
  end

  test "load_allowed_tools returns empty set for corrupt JSON" do
    thread_id = "thread-1"
    path = File.join(@tmp_dir, "#{thread_id}.json")
    File.write(path, "not json{{{")

    handler = build_handler
    allowed = handler.instance_variable_get(:@allowed_tools)
    assert allowed.empty?
  end

  test "save_allowed_tools creates directory and writes file" do
    handler = build_handler
    handler.instance_variable_get(:@allowed_tools).add("Bash")
    handler.instance_variable_get(:@allowed_tools).add("Edit")
    handler.send(:save_allowed_tools)

    path = handler.send(:allowed_tools_path)
    assert File.exist?(path)

    saved = Set.new(JSON.parse(File.read(path)))
    assert_equal Set.new(%w[Bash Edit]), saved
  end

  test "post_permission_request formats message with tool_name and always allow text" do
    posts = []
    handler = build_handler_with_tracking(posts: posts)

    post_id = handler.send(:post_permission_request, "Bash", { "command" => "echo hello" })

    assert_equal "perm-post-1", post_id
    assert_equal 1, posts.size
    message = posts.first[:body][:message]
    assert_includes message, "Bash"
    assert_includes message, "echo hello"
    assert_includes message, "always allow `Bash`"
    assert_not_includes message, "allow all"
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

  # --- Handler interface tests ---

  test "tool_definitions returns permission_prompt tool" do
    handler = build_handler
    defs = handler.tool_definitions

    assert_equal 1, defs.size
    assert_equal "permission_prompt", defs.first[:name]
    assert defs.first.key?(:inputSchema)
  end

  test "handles? returns true for permission_prompt" do
    handler = build_handler
    assert handler.handles?("permission_prompt")
  end

  test "handles? returns false for other tools" do
    handler = build_handler
    assert_not handler.handles?("save_memory")
    assert_not handler.handles?("Bash")
  end

  test "call delegates to handle and wraps result in MCP content format" do
    handler = build_handler
    handler.instance_variable_get(:@allowed_tools).add("Bash")

    result = handler.call("permission_prompt", { "tool_name" => "Bash", "input" => { "command" => "ls" } })

    assert result.key?(:content)
    assert_equal 1, result[:content].size
    assert_equal "text", result[:content].first[:type]

    parsed = JSON.parse(result[:content].first[:text])
    assert_equal "allow", parsed["behavior"]
  end

  test "multiple tools can be independently allowed" do
    handler = build_handler
    handler.send(:process_reaction, "white_check_mark", "Bash", { "command" => "ls" })
    handler.send(:process_reaction, "white_check_mark", "Read", { "path" => "/tmp" })

    allowed = handler.instance_variable_get(:@allowed_tools)
    assert allowed.include?("Bash")
    assert allowed.include?("Read")
    assert_not allowed.include?("Edit")
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
