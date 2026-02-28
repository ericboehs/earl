# frozen_string_literal: true

require "test_helper"

module Earl
  module Mcp
    class TmuxHandlerTest < Minitest::Test
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
        stub_singleton(@tmux, :send_keys_raw) { |_t, _k| raise Earl::Tmux::NotFound, "not found" }
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
        @handler.call("manage_tmux_sessions",
                      { "action" => "send_input", "target" => "dev:1.0", "text" => "hello world" })
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

      test "kill returns error for missing session and cleans up store" do
        stub_singleton(@tmux, :kill_session) { |_n| raise Earl::Tmux::NotFound, "not found" }
        result = @handler.call("manage_tmux_sessions", { "action" => "kill", "target" => "missing" })
        text = result[:content].first[:text]
        assert_includes text, "not found"
        assert_equal ["missing"], @tmux_store.deleted
      end

      # --- spawn ---

      test "spawn returns error when prompt missing" do
        result = @handler.call("manage_tmux_sessions", { "action" => "spawn" })
        text = result[:content].first[:text]
        assert_includes text, "prompt is required"
      end

      test "spawn returns error when session name contains dot" do
        result = @handler.call("manage_tmux_sessions", {
                                 "action" => "spawn", "prompt" => "fix tests", "name" => "bad.name"
                               })
        text = result[:content].first[:text]
        assert_includes text, "cannot contain"
      end

      test "spawn returns error when session name contains colon" do
        result = @handler.call("manage_tmux_sessions", {
                                 "action" => "spawn", "prompt" => "fix tests", "name" => "bad:name"
                               })
        text = result[:content].first[:text]
        assert_includes text, "cannot contain"
      end

      test "spawn allows dot and colon in window name when session param provided" do
        @tmux.session_exists_result = true
        stub_singleton(@handler, :request_spawn_confirmation) { |_| :approved }

        result = @handler.call("manage_tmux_sessions", {
                                 "action" => "spawn", "prompt" => "fix tests", "name" => "window.with:chars",
                                 "session" => "code"
                               })
        text = result[:content].first[:text]
        assert_includes text, "Spawned"
        assert_equal 1, @tmux.created_windows.size
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
                                 "working_dir" => "/nonexistent/path/that/does/not/exist"
                               })
        text = result[:content].first[:text]
        assert_includes text, "not found"
      end

      test "spawn creates session when confirmation is approved" do
        @tmux.session_exists_result = false
        stub_singleton(@handler, :request_spawn_confirmation) { |_| :approved }

        result = @handler.call("manage_tmux_sessions", {
                                 "action" => "spawn", "prompt" => "fix tests", "name" => "test-session"
                               })
        text = result[:content].first[:text]
        assert_includes text, "Spawned"
        assert_equal 1, @tmux.created_sessions.size
        assert_equal 1, @tmux_store.saved.size
      end

      test "spawn creates window in existing session when session param provided" do
        @tmux.session_exists_result = true
        stub_singleton(@handler, :request_spawn_confirmation) { |_| :approved }

        result = @handler.call("manage_tmux_sessions", {
                                 "action" => "spawn", "prompt" => "fix tests", "name" => "test-window",
                                 "session" => "code"
                               })
        text = result[:content].first[:text]
        assert_includes text, "Spawned"
        assert_includes text, "window in `code`"
        assert_equal 0, @tmux.created_sessions.size
        assert_equal 1, @tmux.created_windows.size
        assert_equal "code", @tmux.created_windows.first[:session]
      end

      test "spawn returns denied message when confirmation is rejected" do
        @tmux.session_exists_result = false
        stub_singleton(@handler, :request_spawn_confirmation) { |_| :denied }

        result = @handler.call("manage_tmux_sessions", {
                                 "action" => "spawn", "prompt" => "fix tests", "name" => "test-session"
                               })
        text = result[:content].first[:text]
        assert_includes text, "denied"
        assert_equal 0, @tmux.created_sessions.size
        assert_equal 0, @tmux_store.saved.size
      end

      test "spawn returns error when confirmation fails" do
        @tmux.session_exists_result = false
        stub_singleton(@handler, :request_spawn_confirmation) { |_| :error }

        result = @handler.call("manage_tmux_sessions", {
                                 "action" => "spawn", "prompt" => "fix tests", "name" => "test-session"
                               })
        text = result[:content].first[:text]
        assert_includes text, "spawn confirmation failed"
        assert_equal 0, @tmux.created_sessions.size
      end

      test "spawn returns error when prompt is blank whitespace" do
        result = @handler.call("manage_tmux_sessions", { "action" => "spawn", "prompt" => "   " })
        text = result[:content].first[:text]
        assert_includes text, "prompt is required"
      end

      test "spawn returns error when session param points to nonexistent session" do
        @tmux.session_exists_result = false
        result = @handler.call("manage_tmux_sessions", {
                                 "action" => "spawn", "prompt" => "fix tests", "session" => "nonexistent"
                               })
        text = result[:content].first[:text]
        assert_includes text, "not found"
      end

      # --- deny error handling ---

      test "deny returns error for missing session" do
        stub_singleton(@tmux, :send_keys_raw) { |_t, _k| raise Earl::Tmux::NotFound, "not found" }
        result = @handler.call("manage_tmux_sessions", { "action" => "deny", "target" => "missing:1.0" })
        text = result[:content].first[:text]
        assert_includes text, "not found"
      end

      # --- send_input error handling ---

      test "send_input returns not found error for missing session" do
        stub_singleton(@tmux, :send_keys) { |_t, _txt| raise Earl::Tmux::NotFound, "not found" }
        result = @handler.call("manage_tmux_sessions",
                               { "action" => "send_input", "target" => "missing:1.0", "text" => "hi" })
        text = result[:content].first[:text]
        assert_includes text, "session/pane 'missing:1.0' not found"
      end

      test "send_input returns error for generic tmux error" do
        stub_singleton(@tmux, :send_keys) { |_t, _txt| raise Earl::Tmux::Error, "pane dead" }
        result = @handler.call("manage_tmux_sessions",
                               { "action" => "send_input", "target" => "x:1.0", "text" => "hi" })
        text = result[:content].first[:text]
        assert_includes text, "pane dead"
      end

      # --- capture edge cases ---

      test "capture floors lines at 1 for negative values" do
        @tmux.capture_pane_result = "output"
        result = @handler.call("manage_tmux_sessions", { "action" => "capture", "target" => "x:1.0", "lines" => -5 })
        text = result[:content].first[:text]
        assert_includes text, "last 1 lines"
      end

      test "capture returns error for generic tmux error" do
        @tmux.capture_pane_error = Earl::Tmux::Error.new("connection refused")
        result = @handler.call("manage_tmux_sessions", { "action" => "capture", "target" => "x:1.0" })
        text = result[:content].first[:text]
        assert_includes text, "connection refused"
      end

      # --- status edge cases ---

      test "status detects permission status" do
        @tmux.capture_pane_result = "some text\nDo you want to proceed?\n"
        result = @handler.call("manage_tmux_sessions", { "action" => "status", "target" => "code:1.0" })
        text = result[:content].first[:text]
        assert_includes text, "Waiting for permission"
      end

      # --- spawn confirmation flow (WebSocket) ---

      test "post_confirmation_request posts to correct channel and thread" do
        handler = build_handler_with_api(post_success: true)
        request = Earl::Mcp::TmuxHandler::SpawnRequest.new(
          name: "test-session", prompt: "fix tests", working_dir: "/tmp", session: nil
        )
        post_id = handler.send(:post_confirmation_request, request)
        assert_equal "spawn-post-1", post_id
      end

      test "post_confirmation_request returns nil when API fails" do
        handler = build_handler_with_api(post_success: false)
        request = Earl::Mcp::TmuxHandler::SpawnRequest.new(
          name: "test-session", prompt: "fix tests", working_dir: "/tmp", session: nil
        )
        post_id = handler.send(:post_confirmation_request, request)
        assert_nil post_id
      end

      test "post_confirmation_request includes session info for window spawn" do
        posts = []
        handler = build_handler_with_api(post_success: true, posts: posts)
        request = Earl::Mcp::TmuxHandler::SpawnRequest.new(name: "test-win", prompt: "fix tests", working_dir: "/tmp",
                                                           session: "code")
        handler.send(:post_confirmation_request, request)
        message = posts.first[:body][:message]
        assert_includes message, "code"
        assert_includes message, "new window"
      end

      test "add_reaction_options adds all three emojis" do
        posts = []
        handler = build_handler_with_api(post_success: true, posts: posts)
        handler.send(:add_reaction_options, "post-1")
        reaction_posts = posts.select { |p| p[:path] == "/reactions" }
        assert_equal 3, reaction_posts.size
        assert_equal(%w[+1 white_check_mark -1], reaction_posts.map { |r| r[:body][:emoji_name] })
      end

      test "delete_confirmation_post calls delete on api" do
        handler = build_handler_with_api(post_success: true)
        api = handler.instance_variable_get(:@api)
        deletes = []
        stub_singleton(api, :delete) { |path| deletes << path }
        handler.send(:delete_confirmation_post, "post-1")
        assert_equal ["/posts/post-1"], deletes
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

      test "wait_for_confirmation returns error when websocket connection fails" do
        stub_singleton(@handler, :connect_websocket) { nil }
        result = @handler.send(:wait_for_confirmation, "post-123")
        assert_equal :error, result
      end

      test "request_spawn_confirmation returns error when post fails" do
        handler = build_handler_with_api(post_success: false)
        request = Earl::Mcp::TmuxHandler::SpawnRequest.new(name: "test", prompt: "hi", working_dir: "/tmp",
                                                           session: nil)
        result = handler.send(:request_spawn_confirmation, request)
        assert_equal :error, result
      end

      # --- additional branch coverage ---

      test "capture uses explicit lines argument when provided" do
        @tmux.capture_pane_result = "explicit line output"
        result = @handler.call("manage_tmux_sessions",
                               { "action" => "capture", "target" => "x:1.0", "lines" => 50 })
        text = result[:content].first[:text]
        assert_includes text, "last 50 lines"
        assert_includes text, "explicit line output"
      end

      test "capture floors lines at 1 for zero value" do
        @tmux.capture_pane_result = "output"
        result = @handler.call("manage_tmux_sessions",
                               { "action" => "capture", "target" => "x:1.0", "lines" => 0 })
        text = result[:content].first[:text]
        assert_includes text, "last 1 lines"
      end

      test "status returns not found error for missing session" do
        @tmux.capture_pane_error = Earl::Tmux::NotFound.new("pane gone")
        result = @handler.call("manage_tmux_sessions", { "action" => "status", "target" => "gone:1.0" })
        text = result[:content].first[:text]
        assert_includes text, "session/pane 'gone:1.0' not found"
      end

      test "status returns generic tmux error" do
        @tmux.capture_pane_error = Earl::Tmux::Error.new("tmux crashed")
        result = @handler.call("manage_tmux_sessions", { "action" => "status", "target" => "x:1.0" })
        text = result[:content].first[:text]
        assert_includes text, "tmux crashed"
      end

      test "approve returns generic tmux error" do
        stub_singleton(@tmux, :send_keys_raw) { |_t, _k| raise Earl::Tmux::Error, "pane dead" }
        result = @handler.call("manage_tmux_sessions", { "action" => "approve", "target" => "x:1.0" })
        text = result[:content].first[:text]
        assert_includes text, "pane dead"
      end

      test "deny returns generic tmux error" do
        stub_singleton(@tmux, :send_keys_raw) { |_t, _k| raise Earl::Tmux::Error, "pane dead" }
        result = @handler.call("manage_tmux_sessions", { "action" => "deny", "target" => "x:1.0" })
        text = result[:content].first[:text]
        assert_includes text, "pane dead"
      end

      test "kill returns generic tmux error" do
        stub_singleton(@tmux, :kill_session) { |_n| raise Earl::Tmux::Error, "session locked" }
        result = @handler.call("manage_tmux_sessions", { "action" => "kill", "target" => "locked" })
        text = result[:content].first[:text]
        assert_includes text, "session locked"
      end

      test "spawn returns tmux error when session creation fails" do
        @tmux.session_exists_result = false
        stub_singleton(@handler, :request_spawn_confirmation) { |_| :approved }
        stub_singleton(@tmux, :create_session) { |**_| raise Earl::Tmux::Error, "tmux not running" }

        result = @handler.call("manage_tmux_sessions", {
                                 "action" => "spawn", "prompt" => "fix tests", "name" => "test-session"
                               })
        text = result[:content].first[:text]
        assert_includes text, "tmux not running"
      end

      test "validate_call_args returns nil for valid action with target" do
        result = @handler.send(:validate_call_args, { "action" => "capture", "target" => "x:1.0" })
        assert_nil result
      end

      test "target_required_but_missing returns false for list action" do
        result = @handler.send(:target_required_but_missing?, "list", {})
        assert_equal false, result
      end

      test "target_required_but_missing returns false for spawn action" do
        result = @handler.send(:target_required_but_missing?, "spawn", {})
        assert_equal false, result
      end

      test "target_required_but_missing returns false when target is present" do
        result = @handler.send(:target_required_but_missing?, "capture", { "target" => "x:1.0" })
        assert_equal false, result
      end

      test "target_required_but_missing returns true when target is absent" do
        result = @handler.send(:target_required_but_missing?, "capture", {})
        assert_equal true, result
      end

      test "close_websocket handles nil websocket gracefully" do
        @handler.send(:close_websocket, nil)
      end

      test "close_websocket handles IOError on close" do
        ws = Object.new
        stub_singleton(ws, :close) { raise IOError, "broken pipe" }
        @handler.send(:close_websocket, ws)
      end

      test "parse_reaction_event returns nil for empty message data" do
        msg = Object.new
        stub_singleton(msg, :data) { "" }
        result = @handler.send(:parse_reaction_event, msg)
        assert_nil result
      end

      test "parse_reaction_event returns nil for nil message data" do
        msg = Object.new
        stub_singleton(msg, :data) { nil }
        result = @handler.send(:parse_reaction_event, msg)
        assert_nil result
      end

      test "parse_reaction_event returns nil for non-reaction events" do
        msg = Object.new
        stub_singleton(msg, :data) { JSON.generate({ "event" => "posted", "data" => {} }) }
        result = @handler.send(:parse_reaction_event, msg)
        assert_nil result
      end

      test "parse_reaction_event returns nil for unparsable JSON" do
        msg = Object.new
        stub_singleton(msg, :data) { "not json {{{" }
        result = @handler.send(:parse_reaction_event, msg)
        assert_nil result
      end

      test "parse_reaction_event handles missing nested reaction key" do
        msg = Object.new
        stub_singleton(msg, :data) { JSON.generate({ "event" => "reaction_added", "data" => {} }) }
        result = @handler.send(:parse_reaction_event, msg)
        assert_equal({}, result)
      end

      test "classify_reaction returns nil for unrecognized emoji" do
        result = @handler.send(:classify_reaction, { "user_id" => "user-42", "emoji_name" => "smile" })
        assert_nil result
      end

      test "post_confirmation_request returns nil on IOError" do
        api = Object.new
        stub_singleton(api, :post) { |_path, _body| raise IOError, "connection reset" }
        handler = Earl::Mcp::TmuxHandler.new(
          config: @config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        request = Earl::Mcp::TmuxHandler::SpawnRequest.new(
          name: "test", prompt: "hi", working_dir: nil, session: nil
        )
        result = handler.send(:post_confirmation_request, request)
        assert_nil result
      end

      test "post_to_channel returns nil for non-success response" do
        api = Object.new
        stub_singleton(api, :post) do |_path, _body|
          response = Object.new
          stub_singleton(response, :is_a?) do |klass|
            Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end
        handler = Earl::Mcp::TmuxHandler.new(
          config: @config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        result = handler.send(:post_to_channel, "test message")
        assert_nil result
      end

      test "build_confirmation_message omits dir line when working_dir is nil" do
        request = Earl::Mcp::TmuxHandler::SpawnRequest.new(
          name: "test", prompt: "fix tests", working_dir: nil, session: nil
        )
        message = @handler.send(:build_confirmation_message, request)
        assert_not_includes message, "**Dir:**"
        assert_includes message, "session"
      end

      test "build_confirmation_message includes session line for window spawn" do
        request = Earl::Mcp::TmuxHandler::SpawnRequest.new(
          name: "test-win", prompt: "fix tests", working_dir: "/tmp", session: "code"
        )
        message = @handler.send(:build_confirmation_message, request)
        assert_includes message, "**Dir:** /tmp"
        assert_includes message, "**Session:** code"
        assert_includes message, "window"
      end

      test "delete_confirmation_post swallows errors" do
        api = Object.new
        stub_singleton(api, :delete) { |_path| raise StandardError, "api error" }
        handler = Earl::Mcp::TmuxHandler.new(
          config: @config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        handler.send(:delete_confirmation_post, "post-99")
      end

      test "add_reaction_options logs warning when reaction post fails" do
        handler = build_handler_with_api(post_success: false)
        handler.send(:add_reaction_options, "post-1")
      end

      test "add_reaction_options handles connection error" do
        api = Object.new
        stub_singleton(api, :post) { |_path, _body| raise IOError, "connection lost" }
        handler = Earl::Mcp::TmuxHandler.new(
          config: @config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        handler.send(:add_reaction_options, "post-1")
      end

      test "request_spawn_confirmation deletes post and returns result on success" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket
        stub_singleton(handler, :connect_websocket) { mock_ws }

        Thread.new do
          sleep 0.05
          emit_reaction(mock_ws, post_id: "spawn-post-1", emoji_name: "+1", user_id: "user-42")
        end

        request = Earl::Mcp::TmuxHandler::SpawnRequest.new(
          name: "test", prompt: "hi", working_dir: "/tmp", session: nil
        )
        result = handler.send(:request_spawn_confirmation, request)
        assert_equal :approved, result
      end

      test "wait_for_confirmation polls websocket when connection succeeds" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket
        stub_singleton(handler, :connect_websocket) { mock_ws }

        Thread.new do
          sleep 0.05
          emit_reaction(mock_ws, post_id: "post-123", emoji_name: "-1", user_id: "user-42")
        end

        result = handler.send(:wait_for_confirmation, "post-123")
        assert_equal :denied, result
      end

      test "setup_reaction_listener skips messages where parse returns nil" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket

        Thread.new do
          sleep 0.02
          mock_ws.fire_message("")
          mock_ws.fire_message("not json")
          sleep 0.02
          emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "user-42")
        end

        deadline = Time.now + 5
        result = handler.send(:poll_confirmation, mock_ws, "post-123", deadline)
        assert_equal :approved, result
      end

      test "parse_reaction_event handles nil nested data with safe navigation" do
        msg = Object.new
        stub_singleton(msg, :data) do
          JSON.generate({ "event" => "reaction_added", "data" => { "reaction" => nil } })
        end
        result = @handler.send(:parse_reaction_event, msg)
        assert_equal({}, result)
      end

      test "parse_reaction_event handles absent data key with safe navigation" do
        msg = Object.new
        stub_singleton(msg, :data) do
          JSON.generate({ "event" => "reaction_added" })
        end
        result = @handler.send(:parse_reaction_event, msg)
        assert_equal({}, result)
      end

      test "allowed_reactor returns false when API returns non-success response" do
        config = build_mock_config(allowed_users: %w[alice])
        api = Object.new
        stub_singleton(api, :get) do |_path|
          response = Object.new
          stub_singleton(response, :is_a?) do |klass|
            Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end
        handler = Earl::Mcp::TmuxHandler.new(
          config: config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        result = handler.send(:allowed_reactor?, "unknown-user-id")
        assert_equal false, result
      end

      # --- Mock helpers ---

      private

      # Reusable mock tmux adapter matching command_executor_test.rb pattern
      class MockTmuxAdapter
        attr_accessor :available_result, :list_all_panes_result, :claude_on_tty_results,
                      :capture_pane_result, :capture_pane_error, :session_exists_result
        attr_reader :killed_sessions, :created_sessions, :created_windows, :send_keys_calls, :send_keys_raw_calls

        def initialize
          @available_result = true
          @list_all_panes_result = []
          @claude_on_tty_results = {}
          @capture_pane_result = ""
          @capture_pane_error = nil
          @session_exists_result = false
          @killed_sessions = []
          @created_sessions = []
          @created_windows = []
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

        def session_exists?(_name) = @session_exists_result

        def create_session(name:, command: nil, working_dir: nil)
          @created_sessions << { name: name, command: command, working_dir: working_dir }
        end

        def create_window(session:, name: nil, command: nil, working_dir: nil)
          @created_windows << { session: session, name: name, command: command, working_dir: working_dir }
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

        def get(_path)
          nil
        end

        def delete(path)
          @deletes << path
        end
      end

      def build_mock_config(allowed_users: [])
        config = Object.new
        users = allowed_users
        stub_singleton(config, :platform_channel_id) { "channel-123" }
        stub_singleton(config, :platform_thread_id) { "thread-123" }
        stub_singleton(config, :platform_bot_id) { "bot-123" }
        stub_singleton(config, :permission_timeout_ms) { 120_000 }
        stub_singleton(config, :websocket_url) { "wss://mm.example.com/api/v4/websocket" }
        stub_singleton(config, :platform_token) { "mock-token" }
        stub_singleton(config, :allowed_users) { users }
        config
      end

      def build_handler_with_api(post_success:, posts: nil, allowed_users: [])
        config = build_mock_config(allowed_users: allowed_users)
        tracked_posts = posts || []

        api = Object.new
        psts = tracked_posts

        if post_success
          stub_singleton(api, :post) do |path, body|
            psts << { path: path, body: body }
            response = Object.new
            stub_singleton(response, :body) { JSON.generate({ "id" => "spawn-post-1" }) }
            stub_singleton(response, :is_a?) do |klass|
              klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
            end
            response
          end
        else
          stub_singleton(api, :post) do |path, body|
            psts << { path: path, body: body }
            response = Object.new
            stub_singleton(response, :body) { '{"error":"fail"}' }
            stub_singleton(response, :is_a?) do |klass|
              Object.instance_method(:is_a?).bind_call(self, klass)
            end
            response
          end
        end

        stub_singleton(api, :delete) { |_path| Object.new }

        stub_singleton(api, :get) do |path|
          response = Object.new
          # Return "alice" for alice-uid, "bob" for others
          username = path.include?("alice-uid") ? "alice" : "bob"
          uname = username
          stub_singleton(response, :body) { JSON.generate({ "id" => "user-1", "username" => uname }) }
          stub_singleton(response, :is_a?) do |klass|
            klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end

        handler = Earl::Mcp::TmuxHandler.new(
          config: config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )

        # Speed up dequeue_reaction poll sleep from 0.5s to 0.01s for tests
        stub_singleton(handler, :dequeue_reaction) do |queue|
          queue.pop(true)
        rescue ThreadError
          sleep 0.01
          nil
        end

        handler
      end

      def build_mock_websocket
        ws = Object.new
        ws.instance_variable_set(:@handlers, {})
        stub_singleton(ws, :on) do |event, &block|
          @handlers[event] = block
        end
        stub_singleton(ws, :close) {}
        stub_singleton(ws, :fire_message) do |data|
          handler = @handlers[:message]
          return unless handler

          msg = Object.new
          stub_singleton(msg, :data) { data }
          stub_singleton(msg, :empty?) { data.nil? || data.empty? }
          handler.call(msg)
        end
        ws
      end

      def emit_reaction(mock_ws, post_id:, emoji_name:, user_id:)
        reaction = JSON.generate({
                                   "post_id" => post_id,
                                   "user_id" => user_id,
                                   "emoji_name" => emoji_name
                                 })
        event = JSON.generate({
                                "event" => "reaction_added",
                                "data" => { "reaction" => reaction }
                              })
        mock_ws.fire_message(event)
      end
    end
  end
end
