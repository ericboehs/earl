# frozen_string_literal: true

require "test_helper"

class Earl::Mcp::TmuxHandlerTest < ActiveSupport::TestCase
  setup do
    @tmux = MockTmuxAdapter.new
    @tmux_store = MockTmuxStore.new
    @config = build_mock_config
    @api = MockApiClient.new
    @handler = Earl::Mcp::TmuxHandler.new(
      config: @config, api_client: @api,
      tmux_store: @tmux_store, tmux_adapter: @tmux
    )
  end

  # --- tool_definitions ---

  test "tool_definitions returns one tool" do
    defs = @handler.tool_definitions
    assert_equal 1, defs.size
    assert_equal "manage_tmux_sessions", defs.first[:name]
  end

  test "tool_definitions includes inputSchema with action as required" do
    schema = @handler.tool_definitions.first[:inputSchema]
    assert_equal "object", schema[:type]
    assert_includes schema[:required], "action"
  end

  # --- handles? ---

  test "handles? returns true for manage_tmux_sessions" do
    assert @handler.handles?("manage_tmux_sessions")
  end

  test "handles? returns false for other tools" do
    assert_not @handler.handles?("manage_heartbeat")
  end

  # --- action validation ---

  test "call returns error when action is missing" do
    result = @handler.call("manage_tmux_sessions", {})
    text = result[:content].first[:text]
    assert_includes text, "action is required"
  end

  test "call returns error for unknown action" do
    result = @handler.call("manage_tmux_sessions", { "action" => "explode" })
    text = result[:content].first[:text]
    assert_includes text, "unknown action"
  end

  test "call returns nil for unhandled tool name" do
    result = @handler.call("other_tool", { "action" => "list" })
    assert_nil result
  end

  # --- list ---

  test "list returns error when tmux not available" do
    @tmux.available_result = false
    result = @handler.call("manage_tmux_sessions", { "action" => "list" })
    text = result[:content].first[:text]
    assert_includes text, "not available"
  end

  test "list returns message when no tmux sessions" do
    @tmux.available_result = true
    @tmux.list_all_panes_result = []
    result = @handler.call("manage_tmux_sessions", { "action" => "list" })
    text = result[:content].first[:text]
    assert_includes text, "No tmux sessions"
  end

  test "list returns message when no Claude sessions found" do
    @tmux.available_result = true
    @tmux.list_all_panes_result = [
      { target: "chat:1.0", session: "chat", window: 1, pane_index: 0,
        command: "weechat", path: "/home/user", pid: 300, tty: "/dev/ttys003" }
    ]
    @tmux.claude_on_tty_results = { "/dev/ttys003" => false }
    result = @handler.call("manage_tmux_sessions", { "action" => "list" })
    text = result[:content].first[:text]
    assert_includes text, "No Claude sessions"
  end

  test "list returns formatted Claude sessions" do
    @tmux.available_result = true
    @tmux.list_all_panes_result = [
      { target: "code:1.0", session: "code", window: 1, pane_index: 0,
        command: "2.1.42", path: "/home/user/earl", pid: 100, tty: "/dev/ttys001" },
      { target: "code:2.0", session: "code", window: 2, pane_index: 0,
        command: "2.1.42", path: "/home/user/other", pid: 200, tty: "/dev/ttys002" }
    ]
    @tmux.claude_on_tty_results = { "/dev/ttys001" => true, "/dev/ttys002" => true }
    @tmux.capture_pane_result = "working on stuff\n"

    result = @handler.call("manage_tmux_sessions", { "action" => "list" })
    text = result[:content].first[:text]
    assert_includes text, "code:1.0"
    assert_includes text, "code:2.0"
    assert_includes text, "earl"
  end

  test "list detects active status from capture output" do
    @tmux.available_result = true
    @tmux.list_all_panes_result = [
      { target: "code:1.0", session: "code", window: 1, pane_index: 0,
        command: "claude", path: "/home/user/earl", pid: 100, tty: "/dev/ttys001" }
    ]
    @tmux.claude_on_tty_results = { "/dev/ttys001" => true }
    @tmux.capture_pane_result = "some output\nesc to interrupt\n"

    result = @handler.call("manage_tmux_sessions", { "action" => "list" })
    text = result[:content].first[:text]
    assert_includes text, "Active"
  end

  test "list detects permission status from capture output" do
    @tmux.available_result = true
    @tmux.list_all_panes_result = [
      { target: "code:1.0", session: "code", window: 1, pane_index: 0,
        command: "claude", path: "/home/user/earl", pid: 100, tty: "/dev/ttys001" }
    ]
    @tmux.claude_on_tty_results = { "/dev/ttys001" => true }
    @tmux.capture_pane_result = "Do you want to proceed?\n"

    result = @handler.call("manage_tmux_sessions", { "action" => "list" })
    text = result[:content].first[:text]
    assert_includes text, "Waiting for permission"
  end

  test "list shows idle when capture has no status indicators" do
    @tmux.available_result = true
    @tmux.list_all_panes_result = [
      { target: "code:1.0", session: "code", window: 1, pane_index: 0,
        command: "claude", path: "/home/user/earl", pid: 100, tty: "/dev/ttys001" }
    ]
    @tmux.claude_on_tty_results = { "/dev/ttys001" => true }
    @tmux.capture_pane_result = "just chilling\n"

    result = @handler.call("manage_tmux_sessions", { "action" => "list" })
    text = result[:content].first[:text]
    assert_includes text, "Idle"
  end

  test "list shows idle when capture_pane raises error" do
    @tmux.available_result = true
    @tmux.list_all_panes_result = [
      { target: "code:1.0", session: "code", window: 1, pane_index: 0,
        command: "claude", path: "/home/user/earl", pid: 100, tty: "/dev/ttys001" }
    ]
    @tmux.claude_on_tty_results = { "/dev/ttys001" => true }
    @tmux.capture_pane_error = Earl::Tmux::Error.new("tmux error")

    result = @handler.call("manage_tmux_sessions", { "action" => "list" })
    text = result[:content].first[:text]
    assert_includes text, "Idle"
  end

  # --- capture ---

  test "capture returns error when target is missing" do
    result = @handler.call("manage_tmux_sessions", { "action" => "capture" })
    text = result[:content].first[:text]
    assert_includes text, "target is required"
  end

  test "capture returns pane output" do
    @tmux.capture_pane_result = "line 1\nline 2\nline 3\n"
    result = @handler.call("manage_tmux_sessions", { "action" => "capture", "target" => "code:1.0" })
    text = result[:content].first[:text]
    assert_includes text, "line 1"
    assert_includes text, "line 3"
  end

  test "capture returns error for missing session" do
    @tmux.capture_pane_error = Earl::Tmux::NotFound.new("not found")
    result = @handler.call("manage_tmux_sessions", { "action" => "capture", "target" => "missing:1.0" })
    text = result[:content].first[:text]
    assert_includes text, "not found"
  end

  # --- status ---

  test "status returns error when target is missing" do
    result = @handler.call("manage_tmux_sessions", { "action" => "status" })
    text = result[:content].first[:text]
    assert_includes text, "target is required"
  end

  test "status returns pane output with status label" do
    @tmux.capture_pane_result = "detailed output\n"
    result = @handler.call("manage_tmux_sessions", { "action" => "status", "target" => "code:1.0" })
    text = result[:content].first[:text]
    assert_includes text, "detailed output"
    assert_includes text, "status"
  end

  # --- approve ---

  test "approve sends Enter to target" do
    @handler.call("manage_tmux_sessions", { "action" => "approve", "target" => "code:4.0" })
    assert_equal 1, @tmux.send_keys_raw_calls.size
    assert_equal({ target: "code:4.0", key: "Enter" }, @tmux.send_keys_raw_calls.first)
  end

  test "approve returns error when target missing" do
    result = @handler.call("manage_tmux_sessions", { "action" => "approve" })
    text = result[:content].first[:text]
    assert_includes text, "target is required"
  end

  test "approve returns error for missing session" do
    @tmux.define_singleton_method(:send_keys_raw) { |_t, _k| raise Earl::Tmux::NotFound, "not found" }
    result = @handler.call("manage_tmux_sessions", { "action" => "approve", "target" => "missing:1.0" })
    text = result[:content].first[:text]
    assert_includes text, "not found"
  end

  # --- deny ---

  test "deny sends Escape to target" do
    @handler.call("manage_tmux_sessions", { "action" => "deny", "target" => "code:4.0" })
    assert_equal 1, @tmux.send_keys_raw_calls.size
    assert_equal({ target: "code:4.0", key: "Escape" }, @tmux.send_keys_raw_calls.first)
  end

  test "deny returns error when target missing" do
    result = @handler.call("manage_tmux_sessions", { "action" => "deny" })
    text = result[:content].first[:text]
    assert_includes text, "target is required"
  end

  # --- send_input ---

  test "send_input sends text to target" do
    @handler.call("manage_tmux_sessions", { "action" => "send_input", "target" => "dev:1.0", "text" => "hello world" })
    assert_equal 1, @tmux.send_keys_calls.size
    assert_equal({ target: "dev:1.0", text: "hello world" }, @tmux.send_keys_calls.first)
  end

  test "send_input returns error when target missing" do
    result = @handler.call("manage_tmux_sessions", { "action" => "send_input", "text" => "hello" })
    text = result[:content].first[:text]
    assert_includes text, "target is required"
  end

  test "send_input returns error when text missing" do
    result = @handler.call("manage_tmux_sessions", { "action" => "send_input", "target" => "dev:1.0" })
    text = result[:content].first[:text]
    assert_includes text, "text is required"
  end

  # --- Mock helpers ---

  private

  # Reusable mock tmux adapter matching command_executor_test.rb pattern
  class MockTmuxAdapter
    attr_accessor :available_result, :list_all_panes_result, :claude_on_tty_results,
                  :capture_pane_result, :capture_pane_error, :session_exists_result
    attr_reader :killed_sessions, :created_sessions, :send_keys_calls, :send_keys_raw_calls

    def initialize
      @available_result = true
      @list_all_panes_result = []
      @claude_on_tty_results = {}
      @capture_pane_result = ""
      @capture_pane_error = nil
      @session_exists_result = false
      @killed_sessions = []
      @created_sessions = []
      @send_keys_calls = []
      @send_keys_raw_calls = []
    end

    def available? = @available_result

    def list_all_panes = @list_all_panes_result

    def claude_on_tty?(tty) = @claude_on_tty_results.fetch(tty, false)

    def capture_pane(_target, lines: 100)
      raise @capture_pane_error if @capture_pane_error

      @capture_pane_result
    end

    def send_keys(target, text)
      @send_keys_calls << { target: target, text: text }
    end

    def send_keys_raw(target, key)
      @send_keys_raw_calls << { target: target, key: key }
    end

    def session_exists?(name) = @session_exists_result

    def create_session(name:, command: nil, working_dir: nil)
      @created_sessions << { name: name, command: command, working_dir: working_dir }
    end

    def kill_session(name)
      @killed_sessions << name
    end
  end

  class MockTmuxStore
    attr_reader :saved, :deleted

    def initialize
      @saved = []
      @deleted = []
    end

    def save(info) = @saved << info
    def delete(name) = @deleted << name
  end

  class MockApiClient
    attr_reader :posts, :reactions, :deletes

    def initialize
      @posts = []
      @reactions = []
      @deletes = []
    end

    def post(path, body)
      @posts << { path: path, body: body }
      nil
    end

    def get(path)
      nil
    end

    def delete(path)
      @deletes << path
    end
  end

  def build_mock_config
    config = Object.new
    config.define_singleton_method(:platform_channel_id) { "channel-123" }
    config.define_singleton_method(:platform_thread_id) { "thread-123" }
    config.define_singleton_method(:platform_bot_id) { "bot-123" }
    config.define_singleton_method(:permission_timeout_ms) { 120_000 }
    config.define_singleton_method(:websocket_url) { "wss://mm.example.com/api/v4/websocket" }
    config.define_singleton_method(:allowed_users) { [] }
    config
  end
end
