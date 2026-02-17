# Tmux MCP Tool Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `manage_tmux_sessions` MCP tool so EARL-spawned Claude sessions can list, capture, approve/deny, send input to, spawn, and kill other Claude sessions running in tmux.

**Architecture:** New `Earl::Mcp::TmuxHandler` class following the existing handler interface (`tool_definitions`, `handles?`, `call`). Single tool with `action` parameter, matching the `HeartbeatHandler` pattern. Spawn action requires Mattermost reaction-based confirmation (reusing `ApprovalHandler` patterns). Wired into `bin/earl-permission-server`.

**Tech Stack:** Ruby, Minitest, tmux CLI via existing `Earl::Tmux` module

**Design doc:** `docs/plans/2026-02-16-tmux-mcp-tool-design.md`

---

### Task 1: TmuxHandler skeleton with tool_definitions, handles?, and list action

**Files:**
- Create: `lib/earl/mcp/tmux_handler.rb`
- Create: `test/lib/earl/mcp/tmux_handler_test.rb`

**Step 1: Write the failing tests**

```ruby
# test/lib/earl/mcp/tmux_handler_test.rb
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

  # --- Mock helpers (at bottom of test file) ---

  private

  # Reusable mock tmux adapter matching command_executor_test.rb pattern
  class MockTmuxAdapter
    attr_accessor :available_result, :list_all_panes_result, :claude_on_tty_results,
                  :capture_pane_result, :capture_pane_error, :session_exists_result,
                  :killed_sessions, :created_sessions, :send_keys_calls, :send_keys_raw_calls

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

    def capture_pane(target, lines: 100)
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
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: Error — `NameError: uninitialized constant Earl::Mcp::TmuxHandler`

**Step 3: Write minimal implementation**

```ruby
# lib/earl/mcp/tmux_handler.rb
# frozen_string_literal: true

module Earl
  module Mcp
    # MCP handler exposing a manage_tmux_sessions tool to list, capture, control,
    # spawn, and kill Claude sessions running in tmux panes.
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class TmuxHandler
      include Logging

      TOOL_NAME = "manage_tmux_sessions"
      VALID_ACTIONS = %w[list capture status approve deny send_input spawn kill].freeze

      PANE_STATUS_LABELS = {
        active: "Active",
        permission: "Waiting for permission",
        idle: "Idle"
      }.freeze

      def initialize(config:, api_client:, tmux_store:, tmux_adapter: Tmux)
        @config = config
        @api = api_client
        @tmux_store = tmux_store
        @tmux = tmux_adapter
      end

      def tool_definitions
        [tool_definition]
      end

      def handles?(name)
        name == TOOL_NAME
      end

      def call(name, arguments)
        return unless name == TOOL_NAME

        action = arguments["action"]
        return text_content("Error: action is required (#{VALID_ACTIONS.join(', ')})") unless action
        return text_content("Error: unknown action '#{action}'. Valid: #{VALID_ACTIONS.join(', ')}") unless VALID_ACTIONS.include?(action)

        send("handle_#{action}", arguments)
      end

      private

      # --- list ---

      def handle_list(_arguments)
        return text_content("Error: tmux is not available") unless @tmux.available?

        panes = @tmux.list_all_panes
        return text_content("No tmux sessions running.") if panes.empty?

        claude_panes = panes.select { |pane| @tmux.claude_on_tty?(pane[:tty]) }
        return text_content("No Claude sessions found across #{panes.size} tmux panes.") if claude_panes.empty?

        lines = claude_panes.map { |pane| format_pane(pane) }
        text_content("**Claude Sessions (#{claude_panes.size}):**\n\n#{lines.join("\n")}")
      end

      def format_pane(pane)
        target = pane[:target]
        project = File.basename(pane[:path])
        status = detect_pane_status(target)
        "- `#{target}` — #{project} (#{PANE_STATUS_LABELS.fetch(status, 'Idle')})"
      end

      def detect_pane_status(target)
        output = @tmux.capture_pane(target, lines: 20)
        return :permission if output.include?("Do you want to proceed?")
        return :active if output.include?("esc to interrupt")

        :idle
      rescue Tmux::Error
        :idle
      end

      # Placeholder stubs for remaining actions (implemented in later tasks)
      def handle_capture(_arguments) = text_content("Not yet implemented")
      def handle_status(_arguments) = text_content("Not yet implemented")
      def handle_approve(_arguments) = text_content("Not yet implemented")
      def handle_deny(_arguments) = text_content("Not yet implemented")
      def handle_send_input(_arguments) = text_content("Not yet implemented")
      def handle_spawn(_arguments) = text_content("Not yet implemented")
      def handle_kill(_arguments) = text_content("Not yet implemented")

      # --- helpers ---

      def text_content(text)
        { content: [{ type: "text", text: text }] }
      end

      def tool_definition
        {
          name: TOOL_NAME,
          description: "Manage Claude sessions running in tmux. " \
                       "List sessions, capture output, approve/deny permissions, send input, spawn new sessions, or kill sessions.",
          inputSchema: {
            type: "object",
            properties: {
              action: {
                type: "string",
                enum: VALID_ACTIONS,
                description: "Action to perform"
              },
              target: {
                type: "string",
                description: "Tmux pane target (e.g., 'session:window.pane'). Required for capture, status, approve, deny, send_input, kill."
              },
              text: {
                type: "string",
                description: "Text to send (required for send_input)"
              },
              lines: {
                type: "integer",
                description: "Number of lines to capture (default 100, for capture action)"
              },
              prompt: {
                type: "string",
                description: "Prompt for new Claude session (required for spawn)"
              },
              name: {
                type: "string",
                description: "Session name for spawn (auto-generated if omitted)"
              },
              working_dir: {
                type: "string",
                description: "Working directory for spawn"
              }
            },
            required: %w[action]
          }
        }
      end
    end
  end
end
```

Also add the require to `lib/earl.rb`:

```ruby
# In the mcp section of requires:
require_relative "earl/mcp/tmux_handler"
```

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/earl/mcp/tmux_handler.rb test/lib/earl/mcp/tmux_handler_test.rb lib/earl.rb
git commit -m "feat: add TmuxHandler skeleton with list action"
```

---

### Task 2: capture and status actions

**Files:**
- Modify: `lib/earl/mcp/tmux_handler.rb`
- Modify: `test/lib/earl/mcp/tmux_handler_test.rb`

**Step 1: Write the failing tests**

Add to the test file:

```ruby
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

test "status returns pane output with more lines" do
  @tmux.capture_pane_result = "detailed output\n"
  result = @handler.call("manage_tmux_sessions", { "action" => "status", "target" => "code:1.0" })
  text = result[:content].first[:text]
  assert_includes text, "detailed output"
end
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: FAIL — stubs return "Not yet implemented"

**Step 3: Write minimal implementation**

Replace the placeholder stubs for `handle_capture` and `handle_status`:

```ruby
def handle_capture(arguments)
  target = arguments["target"]
  return text_content("Error: target is required for capture") unless target

  lines = (arguments["lines"] || 100).to_i
  output = @tmux.capture_pane(target, lines: lines)
  text_content("**`#{target}` output (last #{lines} lines):**\n```\n#{output}\n```")
rescue Tmux::NotFound
  text_content("Error: session/pane '#{target}' not found")
rescue Tmux::Error => error
  text_content("Error: #{error.message}")
end

def handle_status(arguments)
  target = arguments["target"]
  return text_content("Error: target is required for status") unless target

  output = @tmux.capture_pane(target, lines: 200)
  status = detect_pane_status(target)
  text_content(
    "**`#{target}` status: #{PANE_STATUS_LABELS.fetch(status, 'Idle')}**\n```\n#{output}\n```"
  )
rescue Tmux::NotFound
  text_content("Error: session/pane '#{target}' not found")
rescue Tmux::Error => error
  text_content("Error: #{error.message}")
end
```

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/earl/mcp/tmux_handler.rb test/lib/earl/mcp/tmux_handler_test.rb
git commit -m "feat: add capture and status actions to TmuxHandler"
```

---

### Task 3: approve, deny, and send_input actions

**Files:**
- Modify: `lib/earl/mcp/tmux_handler.rb`
- Modify: `test/lib/earl/mcp/tmux_handler_test.rb`

**Step 1: Write the failing tests**

```ruby
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
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: FAIL

**Step 3: Write minimal implementation**

```ruby
def handle_approve(arguments)
  target = arguments["target"]
  return text_content("Error: target is required for approve") unless target

  @tmux.send_keys_raw(target, "Enter")
  text_content("Approved permission on `#{target}`.")
rescue Tmux::NotFound
  text_content("Error: session/pane '#{target}' not found")
rescue Tmux::Error => error
  text_content("Error: #{error.message}")
end

def handle_deny(arguments)
  target = arguments["target"]
  return text_content("Error: target is required for deny") unless target

  @tmux.send_keys_raw(target, "Escape")
  text_content("Denied permission on `#{target}`.")
rescue Tmux::NotFound
  text_content("Error: session/pane '#{target}' not found")
rescue Tmux::Error => error
  text_content("Error: #{error.message}")
end

def handle_send_input(arguments)
  target = arguments["target"]
  return text_content("Error: target is required for send_input") unless target

  input_text = arguments["text"]
  return text_content("Error: text is required for send_input") unless input_text

  @tmux.send_keys(target, input_text)
  text_content("Sent to `#{target}`: `#{input_text}`")
rescue Tmux::NotFound
  text_content("Error: session/pane '#{target}' not found")
rescue Tmux::Error => error
  text_content("Error: #{error.message}")
end
```

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/earl/mcp/tmux_handler.rb test/lib/earl/mcp/tmux_handler_test.rb
git commit -m "feat: add approve, deny, and send_input actions to TmuxHandler"
```

---

### Task 4: kill action

**Files:**
- Modify: `lib/earl/mcp/tmux_handler.rb`
- Modify: `test/lib/earl/mcp/tmux_handler_test.rb`

**Step 1: Write the failing tests**

```ruby
# --- kill ---

test "kill kills session and removes from store" do
  result = @handler.call("manage_tmux_sessions", { "action" => "kill", "target" => "dev" })
  text = result[:content].first[:text]
  assert_includes text, "Killed"
  assert_equal ["dev"], @tmux.killed_sessions
  assert_equal ["dev"], @tmux_store.deleted
end

test "kill returns error when target missing" do
  result = @handler.call("manage_tmux_sessions", { "action" => "kill" })
  text = result[:content].first[:text]
  assert_includes text, "target is required"
end

test "kill returns error for missing session" do
  @tmux.define_singleton_method(:kill_session) { |_n| raise Earl::Tmux::NotFound, "not found" }
  result = @handler.call("manage_tmux_sessions", { "action" => "kill", "target" => "missing" })
  text = result[:content].first[:text]
  assert_includes text, "not found"
end
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: FAIL

**Step 3: Write minimal implementation**

```ruby
def handle_kill(arguments)
  target = arguments["target"]
  return text_content("Error: target is required for kill") unless target

  @tmux.kill_session(target)
  @tmux_store.delete(target)
  text_content("Killed tmux session `#{target}`.")
rescue Tmux::NotFound
  @tmux_store.delete(target)
  text_content("Error: session '#{target}' not found (cleaned up store)")
rescue Tmux::Error => error
  text_content("Error: #{error.message}")
end
```

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/earl/mcp/tmux_handler.rb test/lib/earl/mcp/tmux_handler_test.rb
git commit -m "feat: add kill action to TmuxHandler"
```

---

### Task 5: spawn action with Mattermost confirmation

**Files:**
- Modify: `lib/earl/mcp/tmux_handler.rb`
- Modify: `test/lib/earl/mcp/tmux_handler_test.rb`

This is the most complex action. The confirmation flow uses the same WebSocket reaction polling pattern as `ApprovalHandler`.

**Step 1: Write the failing tests**

For spawn, we test the validation and the confirmation flow edges. The actual WebSocket polling is hard to unit test (same as ApprovalHandler), so we test the validation paths and mock the confirmation result.

```ruby
# --- spawn ---

test "spawn returns error when prompt missing" do
  result = @handler.call("manage_tmux_sessions", { "action" => "spawn" })
  text = result[:content].first[:text]
  assert_includes text, "prompt is required"
end

test "spawn returns error when name contains dot" do
  result = @handler.call("manage_tmux_sessions", {
    "action" => "spawn", "prompt" => "fix tests", "name" => "bad.name"
  })
  text = result[:content].first[:text]
  assert_includes text, "cannot contain"
end

test "spawn returns error when name contains colon" do
  result = @handler.call("manage_tmux_sessions", {
    "action" => "spawn", "prompt" => "fix tests", "name" => "bad:name"
  })
  text = result[:content].first[:text]
  assert_includes text, "cannot contain"
end

test "spawn returns error when session already exists" do
  @tmux.session_exists_result = true
  result = @handler.call("manage_tmux_sessions", {
    "action" => "spawn", "prompt" => "fix tests", "name" => "existing"
  })
  text = result[:content].first[:text]
  assert_includes text, "already exists"
end

test "spawn returns error when working_dir does not exist" do
  @tmux.session_exists_result = false
  result = @handler.call("manage_tmux_sessions", {
    "action" => "spawn", "prompt" => "fix tests", "name" => "test-session",
    "working_dir" => "/nonexistent/path"
  })
  text = result[:content].first[:text]
  assert_includes text, "not found"
end
```

**Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: FAIL

**Step 3: Write minimal implementation**

Add constants and the confirmation flow methods. For the actual WebSocket polling, extract a `request_confirmation` method that posts to Mattermost and waits for a reaction — same pattern as `ApprovalHandler#wait_for_reaction`.

```ruby
APPROVE_EMOJIS = %w[+1 white_check_mark].freeze
DENY_EMOJIS = %w[-1].freeze
REACTION_EMOJIS = %w[+1 -1].freeze

def handle_spawn(arguments)
  prompt = arguments["prompt"]
  return text_content("Error: prompt is required for spawn") unless prompt && !prompt.strip.empty?

  name = arguments["name"] || "earl-#{Time.now.strftime('%Y%m%d%H%M%S')}"
  return text_content("Error: name '#{name}' cannot contain '.' or ':' (tmux reserved)") if name.match?(/[.:]/)

  working_dir = arguments["working_dir"]
  return text_content("Error: directory '#{working_dir}' not found") if working_dir && !Dir.exist?(working_dir)
  return text_content("Error: session '#{name}' already exists") if @tmux.session_exists?(name)

  approved = request_spawn_confirmation(name: name, prompt: prompt, working_dir: working_dir)
  return text_content("Spawn denied by user.") unless approved

  command = "claude #{Shellwords.shellescape(prompt)}"
  @tmux.create_session(name: name, command: command, working_dir: working_dir)

  info = TmuxSessionStore::TmuxSessionInfo.new(
    name: name, channel_id: @config.platform_channel_id,
    thread_id: @config.platform_thread_id,
    working_dir: working_dir, prompt: prompt, created_at: Time.now.iso8601
  )
  @tmux_store.save(info)

  text_content("Spawned tmux session `#{name}`.\n- Prompt: #{prompt}\n- Dir: #{working_dir || Dir.pwd}")
rescue Tmux::Error => error
  text_content("Error: #{error.message}")
end

def request_spawn_confirmation(name:, prompt:, working_dir:)
  post_id = post_confirmation_request(name, prompt, working_dir)
  return false unless post_id

  add_reaction_options(post_id)
  result = wait_for_confirmation(post_id)
  delete_confirmation_post(post_id)
  result
end

def post_confirmation_request(name, prompt, working_dir)
  dir_line = working_dir ? "\n- **Dir:** #{working_dir}" : ""
  message = ":rocket: **Spawn Request**\n" \
            "Claude wants to spawn session `#{name}`\n" \
            "- **Prompt:** #{prompt}#{dir_line}\n" \
            "React: :+1: approve | :-1: deny"

  response = @api.post("/posts", {
    channel_id: @config.platform_channel_id,
    message: message,
    root_id: @config.platform_thread_id
  })

  return unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)["id"]
rescue StandardError => error
  log(:error, "Failed to post spawn confirmation: #{error.message}")
  nil
end

def add_reaction_options(post_id)
  REACTION_EMOJIS.each do |emoji|
    @api.post("/reactions", {
      user_id: @config.platform_bot_id,
      post_id: post_id,
      emoji_name: emoji
    })
  end
end

def wait_for_confirmation(post_id)
  timeout_sec = @config.permission_timeout_ms / 1000.0
  deadline = Time.now + timeout_sec

  ws = connect_websocket
  return false unless ws

  result = poll_confirmation(ws, post_id, deadline)
  result == true
ensure
  ws&.close rescue nil
end

def connect_websocket
  ws = WebSocket::Client::Simple.connect(@config.websocket_url)
  token = @config.platform_token
  ws_ref = ws
  ws.on(:open) { ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } })) }
  ws
rescue StandardError => error
  log(:error, "Spawn confirmation WebSocket failed: #{error.message}")
  nil
end

def poll_confirmation(ws, post_id, deadline)
  reaction_queue = Queue.new

  ws.on(:message) do |msg|
    next unless msg.data && !msg.data.empty?

    begin
      event = JSON.parse(msg.data)
      if event["event"] == "reaction_added"
        reaction_data = JSON.parse(event.dig("data", "reaction") || "{}")
        reaction_queue.push(reaction_data) if reaction_data["post_id"] == post_id
      end
    rescue JSON::ParserError
      nil
    end
  end

  loop do
    remaining = deadline - Time.now
    return false if remaining <= 0

    reaction = begin
      reaction_queue.pop(true)
    rescue ThreadError
      sleep 0.5
      nil
    end

    next unless reaction
    next if reaction["user_id"] == @config.platform_bot_id

    return true if APPROVE_EMOJIS.include?(reaction["emoji_name"])
    return false if DENY_EMOJIS.include?(reaction["emoji_name"])
  end
end

def delete_confirmation_post(post_id)
  @api.delete("/posts/#{post_id}")
rescue StandardError => error
  log(:warn, "Failed to delete spawn confirmation: #{error.message}")
end
```

Also add `require "shellwords"` at the top of the file.

**Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/earl/mcp/tmux_handler_test.rb`
Expected: All tests PASS

**Step 5: Commit**

```bash
git add lib/earl/mcp/tmux_handler.rb test/lib/earl/mcp/tmux_handler_test.rb
git commit -m "feat: add spawn action with Mattermost confirmation to TmuxHandler"
```

---

### Task 6: Wire TmuxHandler into earl-permission-server

**Files:**
- Modify: `bin/earl-permission-server`
- Modify: `lib/earl.rb` (if not already done in Task 1)

**Step 1: Verify current state of earl-permission-server**

Read `bin/earl-permission-server` to confirm handler wiring location.

**Step 2: Add TmuxHandler to the handler list**

Add after the heartbeat_handler initialization:

```ruby
tmux_store = Earl::TmuxSessionStore.new
tmux_handler = Earl::Mcp::TmuxHandler.new(
  config: config, api_client: api_client, tmux_store: tmux_store
)

server = Earl::Mcp::Server.new(
  handlers: [approval_handler, memory_handler, heartbeat_handler, tmux_handler]
)
```

**Step 3: Run full CI to verify nothing breaks**

Run: `bin/ci`
Expected: All tests PASS, rubocop clean

**Step 4: Commit**

```bash
git add bin/earl-permission-server lib/earl.rb
git commit -m "feat: wire TmuxHandler into earl-permission-server"
```

---

### Task 7: Update CLAUDE.md with new MCP tool documentation

**Files:**
- Modify: `CLAUDE.md`

**Step 1: Add tmux_handler to the architecture tree**

Add under `mcp/`:
```
      tmux_handler.rb              # manage_tmux_sessions MCP tool (list, capture, approve, spawn, kill)
```

**Step 2: Add key detail about the new MCP tool**

In the "Key Details" section, add:
```
- **Tmux MCP tool**: `manage_tmux_sessions` tool exposes tmux session control to spawned Claude sessions. Actions: list, capture, status, approve, deny, send_input, spawn (requires Mattermost confirmation), kill.
```

**Step 3: Run full CI**

Run: `bin/ci`
Expected: PASS

**Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add TmuxHandler MCP tool to CLAUDE.md"
```
