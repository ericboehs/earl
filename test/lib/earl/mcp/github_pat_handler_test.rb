# frozen_string_literal: true

require "test_helper"

class Earl::Mcp::GithubPatHandlerTest < ActiveSupport::TestCase
  setup do
    @safari = MockSafariAdapter.new
    @config = build_mock_config
    @api = MockApiClient.new
    @handler = Earl::Mcp::GithubPatHandler.new(
      config: @config, api_client: @api, safari_adapter: @safari
    )
  end

  # --- tool_definitions ---

  test "tool_definitions returns one tool" do
    defs = @handler.tool_definitions
    assert_equal 1, defs.size
    assert_equal "manage_github_pats", defs.first[:name]
  end

  test "tool_definitions includes inputSchema with action as required" do
    schema = @handler.tool_definitions.first[:inputSchema]
    assert_equal "object", schema[:type]
    assert_includes schema[:required], "action"
  end

  # --- handles? ---

  test "handles? returns true for manage_github_pats" do
    assert @handler.handles?("manage_github_pats")
  end

  test "handles? returns false for other tools" do
    assert_not @handler.handles?("manage_tmux_sessions")
  end

  # --- action validation ---

  test "call returns error when action is missing" do
    result = @handler.call("manage_github_pats", {})
    text = result[:content].first[:text]
    assert_includes text, "action is required"
  end

  test "call returns error for unknown action" do
    result = @handler.call("manage_github_pats", { "action" => "destroy" })
    text = result[:content].first[:text]
    assert_includes text, "unknown action"
  end

  test "call returns nil for unhandled tool name" do
    result = @handler.call("other_tool", { "action" => "create" })
    assert_nil result
  end

  # --- create validation ---

  test "create returns error when name is missing" do
    result = @handler.call("manage_github_pats", { "action" => "create" })
    text = result[:content].first[:text]
    assert_includes text, "name is required"
  end

  test "create returns error when name is non-string" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => 123
    })
    text = result[:content].first[:text]
    assert_includes text, "name is required"
  end

  test "create returns error when name is blank" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "  "
    })
    text = result[:content].first[:text]
    assert_includes text, "name is required"
  end

  test "create returns error when repo is missing" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "my-token"
    })
    text = result[:content].first[:text]
    assert_includes text, "repo is required"
  end

  test "create returns error when repo is non-string" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "my-token", "repo" => 42
    })
    text = result[:content].first[:text]
    assert_includes text, "repo is required"
  end

  test "create returns error when repo format is invalid" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "my-token", "repo" => "just-a-name"
    })
    text = result[:content].first[:text]
    assert_includes text, "owner/repo"
  end

  test "create returns error when repo has extra path segments" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "my-token", "repo" => "owner/repo/extra"
    })
    text = result[:content].first[:text]
    assert_includes text, "owner/repo"
  end

  test "create returns error when permissions is missing" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "my-token", "repo" => "owner/repo"
    })
    text = result[:content].first[:text]
    assert_includes text, "permissions is required"
  end

  test "create returns error when permissions is empty hash" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "my-token", "repo" => "owner/repo",
      "permissions" => {}
    })
    text = result[:content].first[:text]
    assert_includes text, "permissions is required"
  end

  test "create returns error when permissions is not a hash" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "my-token", "repo" => "owner/repo",
      "permissions" => "contents:write"
    })
    text = result[:content].first[:text]
    assert_includes text, "permissions is required"
  end

  test "create returns error for unknown permission" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "my-token", "repo" => "owner/repo",
      "permissions" => { "banana" => "write" }
    })
    text = result[:content].first[:text]
    assert_includes text, "unknown permission 'banana'"
  end

  test "create returns error for invalid access level" do
    result = @handler.call("manage_github_pats", {
      "action" => "create", "name" => "my-token", "repo" => "owner/repo",
      "permissions" => { "contents" => "admin" }
    })
    text = result[:content].first[:text]
    assert_includes text, "invalid access level 'admin'"
  end

  # --- permission normalization ---

  test "create normalizes permission access levels to lowercase" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.extract_token_result = "github_pat_test"

    args = valid_create_args.merge("permissions" => { "contents" => "Write" })
    result = @handler.call("manage_github_pats", args)
    text = result[:content].first[:text]
    assert_includes text, "PAT created successfully"
    assert_equal({ "contents" => "write" }, @safari.set_permissions_calls.first)
  end

  # --- expiration validation ---

  test "create returns error when expiration_days is zero" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }

    args = valid_create_args.merge("expiration_days" => 0)
    result = @handler.call("manage_github_pats", args)
    text = result[:content].first[:text]
    assert_includes text, "expiration_days must be a positive integer"
  end

  test "create returns error when expiration_days is negative" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }

    args = valid_create_args.merge("expiration_days" => -30)
    result = @handler.call("manage_github_pats", args)
    text = result[:content].first[:text]
    assert_includes text, "expiration_days must be a positive integer"
  end

  test "create returns error when expiration_days is non-numeric string" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }

    args = valid_create_args.merge("expiration_days" => "abc")
    result = @handler.call("manage_github_pats", args)
    text = result[:content].first[:text]
    assert_includes text, "expiration_days must be a positive integer"
  end

  # --- create approval flow ---

  test "create returns denied when confirmation is rejected" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :denied }

    result = @handler.call("manage_github_pats", valid_create_args)
    text = result[:content].first[:text]
    assert_includes text, "denied"
  end

  test "create returns error when confirmation fails" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :error }

    result = @handler.call("manage_github_pats", valid_create_args)
    text = result[:content].first[:text]
    assert_includes text, "confirmation failed"
  end

  test "create calls safari automation on approval and returns token" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.extract_token_result = "github_pat_ABC123_secret"

    result = @handler.call("manage_github_pats", valid_create_args)
    text = result[:content].first[:text]
    assert_includes text, "PAT created successfully"
    assert_includes text, "my-token"
    assert_includes text, "owner/repo"
    assert_includes text, "github_pat_ABC123_secret"
  end

  test "create returns error when token extraction fails" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.extract_token_result = ""

    result = @handler.call("manage_github_pats", valid_create_args)
    text = result[:content].first[:text]
    assert_includes text, "failed to extract token"
  end

  test "create returns error when token extraction returns nil" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.define_singleton_method(:extract_token) { nil }

    result = @handler.call("manage_github_pats", valid_create_args)
    text = result[:content].first[:text]
    assert_includes text, "failed to extract token"
  end

  test "create returns error when safari automation raises" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.raise_on_navigate = true

    result = @handler.call("manage_github_pats", valid_create_args)
    text = result[:content].first[:text]
    assert_includes text, "Safari automation failed"
  end

  test "create uses default 365 day expiration" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.extract_token_result = "github_pat_test"

    @handler.call("manage_github_pats", valid_create_args)
    assert_equal 365, @safari.set_expiration_calls.first
  end

  test "create uses custom expiration when provided" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.extract_token_result = "github_pat_test"

    args = valid_create_args.merge("expiration_days" => 30)
    @handler.call("manage_github_pats", args)
    assert_equal 30, @safari.set_expiration_calls.first
  end

  test "create navigates to correct GitHub URL" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.extract_token_result = "github_pat_test"

    @handler.call("manage_github_pats", valid_create_args)
    assert_equal "https://github.com/settings/personal-access-tokens/new", @safari.navigated_urls.first
  end

  test "create sets all requested permissions" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.extract_token_result = "github_pat_test"

    args = valid_create_args.merge("permissions" => { "contents" => "write", "issues" => "read" })
    @handler.call("manage_github_pats", args)
    assert_equal({ "contents" => "write", "issues" => "read" }, @safari.set_permissions_calls.first)
  end

  test "create calls safari methods in correct order" do
    @handler.define_singleton_method(:request_create_confirmation) { |_| :approved }
    @safari.extract_token_result = "github_pat_test"

    @handler.call("manage_github_pats", valid_create_args)
    expected = %w[navigate fill_token_name set_expiration select_repository
                  set_permissions click_generate confirm_generation extract_token]
    assert_equal expected, @safari.call_log
  end

  # --- confirmation flow (WebSocket) ---

  test "post_confirmation_request posts to correct channel and thread" do
    handler = build_handler_with_api(post_success: true)
    post_id = handler.send(:post_confirmation_request, sample_pat_request)
    assert_equal "pat-post-1", post_id
  end

  test "post_confirmation_request returns nil when API fails" do
    handler = build_handler_with_api(post_success: false)
    post_id = handler.send(:post_confirmation_request, sample_pat_request)
    assert_nil post_id
  end

  test "post_confirmation_request includes PAT details in message" do
    posts = []
    handler = build_handler_with_api(post_success: true, posts: posts)
    request = sample_pat_request(expiration: 30)
    handler.send(:post_confirmation_request, request)
    message = posts.first[:body][:message]
    assert_includes message, "my-token"
    assert_includes message, "owner/repo"
    assert_includes message, "`contents`: write"
    assert_includes message, "30 days"
  end

  test "add_reaction_options adds all three emojis" do
    posts = []
    handler = build_handler_with_api(post_success: true, posts: posts)
    handler.send(:add_reaction_options, "post-1")
    reaction_posts = posts.select { |p| p[:path] == "/reactions" }
    assert_equal 3, reaction_posts.size
    assert_equal %w[+1 white_check_mark -1], reaction_posts.map { |r| r[:body][:emoji_name] }
  end

  test "delete_confirmation_post calls delete on api" do
    handler = build_handler_with_api(post_success: true)
    api = handler.instance_variable_get(:@api)
    deletes = []
    api.define_singleton_method(:delete) { |path| deletes << path }
    handler.send(:delete_confirmation_post, "post-1")
    assert_equal [ "/posts/post-1" ], deletes
  end

  test "poll_confirmation returns approved on thumbsup reaction" do
    handler = build_handler_with_api(post_success: true)
    mock_ws = build_mock_websocket

    Thread.new do
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "user-42")
    end

    deadline = Time.now + 5
    result = handler.send(:poll_confirmation, mock_ws, "post-123", deadline)
    assert_equal :approved, result
  end

  test "poll_confirmation returns approved on white_check_mark reaction" do
    handler = build_handler_with_api(post_success: true)
    mock_ws = build_mock_websocket

    Thread.new do
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "white_check_mark", user_id: "user-42")
    end

    deadline = Time.now + 5
    result = handler.send(:poll_confirmation, mock_ws, "post-123", deadline)
    assert_equal :approved, result
  end

  test "poll_confirmation returns denied on thumbsdown" do
    handler = build_handler_with_api(post_success: true)
    mock_ws = build_mock_websocket

    Thread.new do
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "-1", user_id: "user-42")
    end

    deadline = Time.now + 5
    result = handler.send(:poll_confirmation, mock_ws, "post-123", deadline)
    assert_equal :denied, result
  end

  test "poll_confirmation returns denied on timeout" do
    handler = build_handler_with_api(post_success: true)
    mock_ws = build_mock_websocket

    deadline = Time.now + 0.2
    result = handler.send(:poll_confirmation, mock_ws, "post-123", deadline)
    assert_equal :denied, result
  end

  test "poll_confirmation ignores bot's own reactions" do
    handler = build_handler_with_api(post_success: true)
    mock_ws = build_mock_websocket

    Thread.new do
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "bot-123")
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "-1", user_id: "user-42")
    end

    deadline = Time.now + 5
    result = handler.send(:poll_confirmation, mock_ws, "post-123", deadline)
    assert_equal :denied, result
  end

  test "poll_confirmation ignores reactions on other posts" do
    handler = build_handler_with_api(post_success: true)
    mock_ws = build_mock_websocket

    Thread.new do
      sleep 0.05
      emit_reaction(mock_ws, post_id: "other-post", emoji_name: "+1", user_id: "user-42")
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "user-42")
    end

    deadline = Time.now + 5
    result = handler.send(:poll_confirmation, mock_ws, "post-123", deadline)
    assert_equal :approved, result
  end

  test "poll_confirmation ignores unrecognized emoji and continues polling" do
    handler = build_handler_with_api(post_success: true)
    mock_ws = build_mock_websocket

    Thread.new do
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "heart", user_id: "user-42")
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "user-42")
    end

    deadline = Time.now + 5
    result = handler.send(:poll_confirmation, mock_ws, "post-123", deadline)
    assert_equal :approved, result
  end

  test "poll_confirmation ignores reactions from unauthorized users" do
    handler = build_handler_with_api(post_success: true, allowed_users: %w[alice])
    mock_ws = build_mock_websocket

    Thread.new do
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "stranger-99")
      sleep 0.05
      emit_reaction(mock_ws, post_id: "post-123", emoji_name: "-1", user_id: "alice-uid")
    end

    deadline = Time.now + 5
    result = handler.send(:poll_confirmation, mock_ws, "post-123", deadline)
    assert_equal :denied, result
  end

  test "allowed_reactor? returns true when allowed_users is empty" do
    assert @handler.send(:allowed_reactor?, "any-user-id")
  end

  test "allowed_reactor? returns false when user lookup fails" do
    config = build_mock_config(allowed_users: %w[alice])
    api = Object.new
    api.define_singleton_method(:get) { |_| raise IOError, "connection reset" }
    handler = Earl::Mcp::GithubPatHandler.new(
      config: config, api_client: api, safari_adapter: @safari
    )
    assert_not handler.send(:allowed_reactor?, "user-123")
  end

  test "wait_for_confirmation returns error when websocket connection fails" do
    @handler.define_singleton_method(:connect_websocket) { nil }
    result = @handler.send(:wait_for_confirmation, "post-123")
    assert_equal :error, result
  end

  test "request_create_confirmation returns error when post fails" do
    handler = build_handler_with_api(post_success: false)
    result = handler.send(:request_create_confirmation, sample_pat_request)
    assert_equal :error, result
  end

  test "request_create_confirmation cleans up confirmation post via ensure" do
    posts = []
    handler = build_handler_with_api(post_success: true, posts: posts)
    handler.define_singleton_method(:wait_for_confirmation) { |_| :denied }

    api = handler.instance_variable_get(:@api)
    deletes = []
    api.define_singleton_method(:delete) { |path| deletes << path }

    handler.send(:request_create_confirmation, sample_pat_request)
    assert_equal [ "/posts/pat-post-1" ], deletes
  end

  # --- SafariAutomation ---

  test "SafariAutomation.execute_js raises Error when osascript fails" do
    original = Open3.method(:capture2e)
    Open3.define_singleton_method(:capture2e) do |*_args|
      status = Object.new
      status.define_singleton_method(:success?) { false }
      status.define_singleton_method(:exitstatus) { 1 }
      [ "error output", status ]
    end

    error = assert_raises(Earl::SafariAutomation::Error) do
      Earl::SafariAutomation.execute_js("bad script")
    end
    assert_includes error.message, "osascript failed"
    assert_includes error.message, "exit 1"
  ensure
    Open3.define_singleton_method(:capture2e, original)
  end

  test "SafariAutomation.execute_js returns output on success" do
    original = Open3.method(:capture2e)
    Open3.define_singleton_method(:capture2e) do |*_args|
      status = Object.new
      status.define_singleton_method(:success?) { true }
      [ "OK\n", status ]
    end

    result = Earl::SafariAutomation.execute_js("good script")
    assert_equal "OK\n", result
  ensure
    Open3.define_singleton_method(:capture2e, original)
  end

  test "SafariAutomation.check_result! raises on NOT_FOUND" do
    error = assert_raises(Earl::SafariAutomation::Error) do
      Earl::SafariAutomation.check_result!("NOT_FOUND:something\n", "test element")
    end
    assert_includes error.message, "Could not find test element"
  end

  test "SafariAutomation.check_result! does not raise on OK" do
    assert_nil Earl::SafariAutomation.check_result!("OK\n", "test element")
  end

  # --- Mock helpers ---

  private

  def valid_create_args
    {
      "action" => "create",
      "name" => "my-token",
      "repo" => "owner/repo",
      "permissions" => { "contents" => "write" }
    }
  end

  def sample_pat_request(expiration: 365)
    Earl::Mcp::GithubPatHandler::PatRequest.new(
      name: "my-token", repo: "owner/repo",
      permissions: { "contents" => "write" }, expiration: expiration
    )
  end

  class MockSafariAdapter
    attr_accessor :extract_token_result, :raise_on_navigate
    attr_reader :navigated_urls, :filled_names, :set_expiration_calls,
                :selected_repos, :set_permissions_calls, :generate_clicked,
                :generation_confirmed, :call_log

    def initialize
      @extract_token_result = "github_pat_default_mock_token"
      @raise_on_navigate = false
      @navigated_urls = []
      @filled_names = []
      @set_expiration_calls = []
      @selected_repos = []
      @set_permissions_calls = []
      @generate_clicked = 0
      @generation_confirmed = 0
      @call_log = []
    end

    def navigate(url)
      raise Earl::SafariAutomation::Error, "mock safari error" if @raise_on_navigate

      @call_log << "navigate"
      @navigated_urls << url
    end

    def fill_token_name(name)
      @call_log << "fill_token_name"
      @filled_names << name
    end

    def set_expiration(days)
      @call_log << "set_expiration"
      @set_expiration_calls << days
    end

    def select_repository(repo)
      @call_log << "select_repository"
      @selected_repos << repo
    end

    def set_permissions(permissions)
      @call_log << "set_permissions"
      @set_permissions_calls << permissions
    end

    def click_generate
      @call_log << "click_generate"
      @generate_clicked += 1
    end

    def confirm_generation
      @call_log << "confirm_generation"
      @generation_confirmed += 1
    end

    def extract_token
      @call_log << "extract_token"
      @extract_token_result
    end
  end

  class MockApiClient
    attr_reader :posts, :deletes

    def initialize
      @posts = []
      @deletes = []
    end

    def post(path, body)
      @posts << { path: path, body: body }
      nil
    end

    def get(_path)
      nil
    end

    def delete(path)
      @deletes << path
    end
  end

  # Mock WebSocket for confirmation flow tests
  class MockWebSocket
    def initialize
      @handlers = {}
    end

    def on(event, &block)
      @handlers[event] = block
    end

    def emit(event, *args)
      @handlers[event]&.call(*args)
    end

    def close; end
    def send(_data); end
  end

  def build_mock_config(allowed_users: [])
    config = Object.new
    users = allowed_users
    config.define_singleton_method(:platform_channel_id) { "channel-123" }
    config.define_singleton_method(:platform_thread_id) { "thread-123" }
    config.define_singleton_method(:platform_bot_id) { "bot-123" }
    config.define_singleton_method(:permission_timeout_ms) { 120_000 }
    config.define_singleton_method(:websocket_url) { "wss://mm.example.com/api/v4/websocket" }
    config.define_singleton_method(:platform_token) { "mock-token" }
    config.define_singleton_method(:allowed_users) { users }
    config
  end

  def build_handler_with_api(post_success:, posts: nil, allowed_users: [])
    config = build_mock_config(allowed_users: allowed_users)
    tracked_posts = posts || []

    api = Object.new
    psts = tracked_posts
    safari = @safari

    if post_success
      api.define_singleton_method(:post) do |path, body|
        psts << { path: path, body: body }
        response = Object.new
        response.define_singleton_method(:body) { JSON.generate({ "id" => "pat-post-1" }) }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end
    else
      api.define_singleton_method(:post) do |path, body|
        psts << { path: path, body: body }
        response = Object.new
        response.define_singleton_method(:body) { '{"error":"fail"}' }
        response.define_singleton_method(:is_a?) do |klass|
          Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end
    end

    api.define_singleton_method(:delete) { |_path| Object.new }

    api.define_singleton_method(:get) do |path|
      response = Object.new
      username = path.include?("alice-uid") ? "alice" : "bob"
      uname = username
      response.define_singleton_method(:body) { JSON.generate({ "id" => "user-1", "username" => uname }) }
      response.define_singleton_method(:is_a?) do |klass|
        klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
      end
      response
    end

    Earl::Mcp::GithubPatHandler.new(
      config: config, api_client: api, safari_adapter: safari
    )
  end

  def build_mock_websocket
    MockWebSocket.new
  end

  def emit_reaction(mock_ws, post_id:, emoji_name:, user_id:)
    reaction_json = JSON.generate({ "post_id" => post_id, "emoji_name" => emoji_name, "user_id" => user_id })
    event_json = JSON.generate({ "event" => "reaction_added", "data" => { "reaction" => reaction_json } })
    msg = Object.new
    data = event_json
    msg.define_singleton_method(:data) { data }
    mock_ws.emit(:message, msg)
  end
end
