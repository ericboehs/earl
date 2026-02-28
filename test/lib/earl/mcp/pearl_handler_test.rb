# frozen_string_literal: true

require "test_helper"

module Earl
  module Mcp
    class PearlHandlerTest < Minitest::Test
      setup do
        @tmux = MockTmuxAdapter.new
        @tmux_store = MockTmuxStore.new
        @config = build_mock_config
        @api = MockApiClient.new
        @handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: @api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
      end

      # --- tool_definitions ---

      test "tool_definitions returns one tool" do
        defs = @handler.tool_definitions
        assert_equal 1, defs.size
        assert_equal "manage_pearl_agents", defs.first[:name]
      end

      test "tool_definitions includes inputSchema with action as required" do
        schema = @handler.tool_definitions.first[:inputSchema]
        assert_equal "object", schema[:type]
        assert_includes schema[:required], "action"
        assert schema[:properties].key?(:target), "Expected target property in schema"
      end

      # --- handles? ---

      test "handles? returns true for manage_pearl_agents" do
        assert @handler.handles?("manage_pearl_agents")
      end

      test "handles? returns false for other tools" do
        assert_not @handler.handles?("manage_tmux_sessions")
      end

      # --- action validation ---

      test "call returns error when action is missing" do
        result = @handler.call("manage_pearl_agents", {})
        text = result[:content].first[:text]
        assert_includes text, "action is required"
      end

      test "call returns error for unknown action" do
        result = @handler.call("manage_pearl_agents", { "action" => "explode" })
        text = result[:content].first[:text]
        assert_includes text, "unknown action"
      end

      test "call returns nil for unhandled tool name" do
        result = @handler.call("other_tool", { "action" => "list_agents" })
        assert_nil result
      end

      # --- list_agents ---

      test "list_agents returns error when pearl bin not found" do
        stub_pearl_bin(nil)
        result = @handler.call("manage_pearl_agents", { "action" => "list_agents" })
        text = result[:content].first[:text]
        assert_includes text, "pearl-agents repo not found"
      end

      test "list_agents returns agents when pearl bin found" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          create_agent_profile(agents_dir, "pptx", skills: false)

          result = @handler.call("manage_pearl_agents", { "action" => "list_agents" })
          text = result[:content].first[:text]
          assert_includes text, "code"
          assert_includes text, "pptx"
          assert_includes text, "skills: yes"
          assert_includes text, "Available PEARL Agents (2)"
        end
      end

      test "list_agents excludes base directory" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          FileUtils.mkdir_p(File.join(agents_dir, "base"))
          File.write(File.join(agents_dir, "base", "Dockerfile"), "FROM node:22")

          result = @handler.call("manage_pearl_agents", { "action" => "list_agents" })
          text = result[:content].first[:text]
          assert_includes text, "code"
          assert_not_includes text, "base"
        end
      end

      test "list_agents returns message when no agents found" do
        with_agents_dir do |_agents_dir|
          result = @handler.call("manage_pearl_agents", { "action" => "list_agents" })
          text = result[:content].first[:text]
          assert_includes text, "No agent profiles found"
        end
      end

      # --- run validation ---

      test "run returns error when agent is missing" do
        result = @handler.call("manage_pearl_agents", { "action" => "run", "prompt" => "hello" })
        text = result[:content].first[:text]
        assert_includes text, "agent is required"
      end

      test "run returns error when agent is blank" do
        result = @handler.call("manage_pearl_agents", { "action" => "run", "agent" => "  ", "prompt" => "hello" })
        text = result[:content].first[:text]
        assert_includes text, "agent is required"
      end

      test "run returns error when prompt is missing" do
        stub_pearl_bin("/usr/local/bin/pearl")
        result = @handler.call("manage_pearl_agents", { "action" => "run", "agent" => "code" })
        text = result[:content].first[:text]
        assert_includes text, "prompt is required"
      end

      test "run returns error when prompt is blank" do
        stub_pearl_bin("/usr/local/bin/pearl")
        result = @handler.call("manage_pearl_agents", { "action" => "run", "agent" => "code", "prompt" => "   " })
        text = result[:content].first[:text]
        assert_includes text, "prompt is required"
      end

      test "run returns error when pearl bin not found" do
        stub_pearl_bin(nil)
        result = @handler.call("manage_pearl_agents", { "action" => "run", "agent" => "code", "prompt" => "hello" })
        text = result[:content].first[:text]
        assert_includes text, "pearl` CLI not found"
      end

      test "run returns error for unknown agent" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "run", "agent" => "nonexistent", "prompt" => "hello"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "unknown agent"
          assert_includes text, "code"
        end
      end

      # --- run spawn flow ---

      test "run creates window when confirmation is approved" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          stub_singleton(@handler, :request_run_confirmation) { |_| :approved }

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "run", "agent" => "code", "prompt" => "fix tests"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "Spawned PEARL agent"
          assert_includes text, "pearl-agents:"
          assert_includes text, "code"
          assert_equal 1, @tmux.created_windows.size
          assert_equal "pearl-agents", @tmux.created_windows.first[:session]
          assert_equal 1, @tmux_store.saved.size
        end
      end

      test "run creates pearl-agents tmux session if it does not exist" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          @tmux.session_exists_result = false
          stub_singleton(@handler, :request_run_confirmation) { |_| :approved }

          @handler.call("manage_pearl_agents", {
                          "action" => "run", "agent" => "code", "prompt" => "fix tests"
                        })
          assert_equal 1, @tmux.created_sessions.size
          assert_equal "pearl-agents", @tmux.created_sessions.first[:name]
        end
      end

      test "run skips session creation if pearl-agents already exists" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          @tmux.session_exists_result = true
          stub_singleton(@handler, :request_run_confirmation) { |_| :approved }

          @handler.call("manage_pearl_agents", {
                          "action" => "run", "agent" => "code", "prompt" => "fix tests"
                        })
          assert_equal 0, @tmux.created_sessions.size
          assert_equal 1, @tmux.created_windows.size
        end
      end

      test "run returns denied message when confirmation is rejected" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          stub_singleton(@handler, :request_run_confirmation) { |_| :denied }

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "run", "agent" => "code", "prompt" => "fix tests"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "denied"
          assert_equal 0, @tmux.created_windows.size
          assert_equal 0, @tmux_store.saved.size
        end
      end

      test "run returns error when confirmation fails" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          stub_singleton(@handler, :request_run_confirmation) { |_| :error }

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "run", "agent" => "code", "prompt" => "fix tests"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "run confirmation failed"
          assert_equal 0, @tmux.created_windows.size
        end
      end

      test "run persists session info with full target name" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          stub_singleton(@handler, :request_run_confirmation) { |_| :approved }

          @handler.call("manage_pearl_agents", {
                          "action" => "run", "agent" => "code", "prompt" => "fix tests"
                        })
          info = @tmux_store.saved.first
          assert info.name.start_with?("pearl-agents:code-")
          assert_equal "channel-123", info.channel_id
          assert_equal "thread-123", info.thread_id
          assert_equal "fix tests", info.prompt
        end
      end

      test "run result includes monitor instructions" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          stub_singleton(@handler, :request_run_confirmation) { |_| :approved }

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "run", "agent" => "code", "prompt" => "fix tests"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "manage_pearl_agents"
          assert_includes text, "status"
          assert_includes text, "Log"
          assert_includes text, "Monitor"
        end
      end

      # --- status ---

      test "status returns error when target is missing" do
        result = @handler.call("manage_pearl_agents", { "action" => "status" })
        text = result[:content].first[:text]
        assert_includes text, "target is required"
      end

      test "status returns error when target is blank" do
        result = @handler.call("manage_pearl_agents", { "action" => "status", "target" => "  " })
        text = result[:content].first[:text]
        assert_includes text, "target is required"
      end

      test "status captures tmux pane output" do
        @tmux.capture_pane_result = "Hello from the agent"
        result = @handler.call("manage_pearl_agents", {
                                 "action" => "status", "target" => "pearl-agents:code-ab12"
                               })
        text = result[:content].first[:text]
        assert_includes text, "pearl-agents:code-ab12"
        assert_includes text, "Hello from the agent"
      end

      test "status falls back to log file when pane not found" do
        @tmux.capture_pane_error = Earl::Tmux::NotFound.new("not found")

        Dir.mktmpdir do |tmpdir|
          log_dir = File.join(tmpdir, "pearl-logs")
          FileUtils.mkdir_p(log_dir)
          File.write(File.join(log_dir, "code-ab12.log"), "Log output here")
          stub_singleton(@handler, :pearl_log_dir) { log_dir }

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "status", "target" => "pearl-agents:code-ab12"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "Log output here"
          assert_includes text, "pane closed"
        end
      end

      test "status returns error when pane not found and no log file" do
        @tmux.capture_pane_error = Earl::Tmux::NotFound.new("not found")

        Dir.mktmpdir do |tmpdir|
          log_dir = File.join(tmpdir, "pearl-logs")
          FileUtils.mkdir_p(log_dir)
          stub_singleton(@handler, :pearl_log_dir) { log_dir }

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "status", "target" => "pearl-agents:code-ab12"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "not found"
          assert_includes text, "no log file"
        end
      end

      # --- confirmation flow ---

      test "post_confirmation_request posts to correct channel and thread" do
        handler = build_handler_with_api(post_success: true)
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "fix tests", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: nil
        )
        post_id = handler.send(:post_confirmation_request, request)
        assert_equal "spawn-post-1", post_id
      end

      test "post_confirmation_request returns nil when API fails" do
        handler = build_handler_with_api(post_success: false)
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "fix tests", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: nil
        )
        post_id = handler.send(:post_confirmation_request, request)
        assert_nil post_id
      end

      test "confirmation message includes agent and prompt" do
        handler = build_handler_with_api(post_success: true)
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "fix tests", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: nil
        )
        message = handler.send(:build_confirmation_message, request)
        assert_includes message, "code"
        assert_includes message, "fix tests"
        assert_includes message, "pearl-agents:code-ab12"
        assert_includes message, "PEARL Agent Request"
      end

      test "add_reaction_options adds all three emojis" do
        posts = []
        handler = build_handler_with_api(post_success: true, posts: posts)
        handler.send(:add_reaction_options, "post-1")
        reaction_posts = posts.select { |post| post[:path] == "/reactions" }
        assert_equal 3, reaction_posts.size
        assert_equal(%w[+1 white_check_mark -1], reaction_posts.map { |post| post[:body][:emoji_name] })
      end

      # --- WebSocket polling ---

      test "polling returns approved on thumbsup reaction" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket

        Thread.new do
          sleep 0.05
          emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "user-42")
        end

        deadline = Time.now + 5
        queue = handler.send(:build_reaction_queue, mock_ws, "post-123")
        result = handler.send(:await_reaction, queue, deadline)
        assert_equal :approved, result
      end

      test "polling returns denied on thumbsdown" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket

        Thread.new do
          sleep 0.05
          emit_reaction(mock_ws, post_id: "post-123", emoji_name: "-1", user_id: "user-42")
        end

        deadline = Time.now + 5
        queue = handler.send(:build_reaction_queue, mock_ws, "post-123")
        result = handler.send(:await_reaction, queue, deadline)
        assert_equal :denied, result
      end

      test "polling returns denied on timeout" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket

        deadline = Time.now + 0.2
        queue = handler.send(:build_reaction_queue, mock_ws, "post-123")
        result = handler.send(:await_reaction, queue, deadline)
        assert_equal :denied, result
      end

      test "polling ignores bot reactions" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket

        Thread.new do
          sleep 0.05
          emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "bot-123")
          sleep 0.05
          emit_reaction(mock_ws, post_id: "post-123", emoji_name: "-1", user_id: "user-42")
        end

        deadline = Time.now + 5
        queue = handler.send(:build_reaction_queue, mock_ws, "post-123")
        result = handler.send(:await_reaction, queue, deadline)
        assert_equal :denied, result
      end

      test "polling ignores reactions on other posts" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket

        Thread.new do
          sleep 0.05
          emit_reaction(mock_ws, post_id: "other-post", emoji_name: "+1", user_id: "user-42")
          sleep 0.05
          emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "user-42")
        end

        deadline = Time.now + 5
        queue = handler.send(:build_reaction_queue, mock_ws, "post-123")
        result = handler.send(:await_reaction, queue, deadline)
        assert_equal :approved, result
      end

      test "wait_for_confirmation returns error when websocket connection fails" do
        stub_singleton(@handler, :connect_websocket) { nil }
        result = @handler.send(:wait_for_confirmation, "post-123")
        assert_equal :error, result
      end

      test "polling responds to ping frames with pong" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket

        pong_sent = false
        stub_singleton(mock_ws, :send) do |_data, **kwargs|
          pong_sent = true if kwargs[:type] == :pong
        end

        Thread.new do
          sleep 0.05
          mock_ws.fire_message(nil, type: :ping)
          sleep 0.05
          emit_reaction(mock_ws, post_id: "post-123", emoji_name: "+1", user_id: "user-42")
        end

        deadline = Time.now + 5
        queue = handler.send(:build_reaction_queue, mock_ws, "post-123")
        result = handler.send(:await_reaction, queue, deadline)

        assert pong_sent, "Expected pong to be sent in response to ping"
        assert_equal :approved, result
      end

      test "request_run_confirmation returns error when post fails" do
        handler = build_handler_with_api(post_success: false)
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "hi", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: nil
        )
        result = handler.send(:request_run_confirmation, request)
        assert_equal :error, result
      end

      # --- RunRequest ---

      test "RunRequest target returns session:window format" do
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "hello", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: nil
        )
        assert_equal "pearl-agents:code-ab12", request.target
      end

      test "RunRequest pearl_command builds correct command" do
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "fix the bug", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: nil
        )
        command = request.pearl_command("/usr/local/bin/pearl")
        assert_includes command, "/usr/local/bin/pearl"
        assert_includes command, "code"
        assert_includes command, "-p"
        assert_includes command, "fix\\ the\\ bug"
        assert_includes command, "tee"
        assert_includes command, "sleep"
      end

      test "RunRequest pearl_command escapes pearl_bin path" do
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "hello", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: nil
        )
        command = request.pearl_command("/path with spaces/pearl")
        assert_includes command, '/path\\ with\\ spaces/pearl'
      end

      test "RunRequest pearl_command includes log path and keep-alive" do
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "hello", window_name: "code-ab12",
          log_path: "/tmp/pearl-logs/code-ab12.log", image_dir: nil
        )
        command = request.pearl_command("/usr/local/bin/pearl")
        assert_includes command, "tee /tmp/pearl-logs/code-ab12.log"
        assert_includes command, "PEARL agent exited"
        assert_includes command, "sleep 300"
      end

      test "RunRequest pearl_command includes PEARL_IMAGES env when image_dir present" do
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "hello", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: "/tmp/pearl-images/code-ab12"
        )
        command = request.pearl_command("/usr/local/bin/pearl")
        assert_includes command, "PEARL_IMAGES=/tmp/pearl-images/code-ab12"
      end

      test "RunRequest pearl_command omits PEARL_IMAGES env when image_dir is nil" do
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "hello", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: nil
        )
        command = request.pearl_command("/usr/local/bin/pearl")
        assert_not_includes command, "PEARL_IMAGES"
      end

      # --- resolve_pearl_bin / find_pearl_in_path ---

      test "resolve_pearl_bin returns PEARL_BIN env when set" do
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: @api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        env_val = "/custom/path/pearl"
        ENV.stub(:fetch, ->(_key, _default) { env_val }) do
          result = handler.send(:resolve_pearl_bin)
          assert_equal "/custom/path/pearl", result
        end
      end

      test "find_pearl_in_path returns path when which succeeds" do
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: @api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        mock_status = Minitest::Mock.new
        mock_status.expect(:success?, true)

        Open3.stub(:capture2e, ["/usr/local/bin/pearl\n", mock_status]) do
          result = handler.send(:find_pearl_in_path)
          assert_equal "/usr/local/bin/pearl", result
        end
        mock_status.verify
      end

      test "find_pearl_in_path returns nil when which fails" do
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: @api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        mock_status = Minitest::Mock.new
        mock_status.expect(:success?, false)

        Open3.stub(:capture2e, ["/usr/local/bin/pearl\n", mock_status]) do
          result = handler.send(:find_pearl_in_path)
          assert_nil result
        end
        mock_status.verify
      end

      test "find_pearl_in_path returns nil on ENOENT" do
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: @api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        Open3.stub(:capture2e, ->(*_) { raise Errno::ENOENT, "which" }) do
          result = handler.send(:find_pearl_in_path)
          assert_nil result
        end
      end

      # --- find_agents_dir / pearl_agents_repo ---

      test "find_agents_dir returns nil when pearl_agents_repo is nil" do
        stub_singleton(@handler, :pearl_agents_repo) { nil }
        result = @handler.send(:find_agents_dir)
        assert_nil result
      end

      test "find_agents_dir returns nil when agents dir does not exist" do
        Dir.mktmpdir do |tmpdir|
          stub_singleton(@handler, :pearl_agents_repo) { tmpdir }
          result = @handler.send(:find_agents_dir)
          assert_nil result
        end
      end

      test "find_agents_dir returns agents dir when it exists" do
        Dir.mktmpdir do |tmpdir|
          agents_dir = File.join(tmpdir, "agents")
          FileUtils.mkdir_p(agents_dir)
          stub_singleton(@handler, :pearl_agents_repo) { tmpdir }
          result = @handler.send(:find_agents_dir)
          assert_equal agents_dir, result
        end
      end

      test "pearl_agents_repo returns nil when resolve_pearl_bin is nil" do
        stub_singleton(@handler, :resolve_pearl_bin) { nil }
        result = @handler.send(:pearl_agents_repo)
        assert_nil result
      end

      test "pearl_agents_repo returns repo path even when agents subdir missing" do
        Dir.mktmpdir do |tmpdir|
          pearl_bin = File.join(tmpdir, "bin", "pearl")
          FileUtils.mkdir_p(File.dirname(pearl_bin))
          File.write(pearl_bin, "#!/bin/bash\n")
          stub_singleton(@handler, :resolve_pearl_bin) { pearl_bin }
          result = @handler.send(:pearl_agents_repo)
          assert_equal tmpdir, result
        end
      end

      test "pearl_agents_repo returns repo path when agents subdir exists" do
        Dir.mktmpdir do |tmpdir|
          pearl_bin = File.join(tmpdir, "bin", "pearl")
          agents_dir = File.join(tmpdir, "agents")
          FileUtils.mkdir_p(File.dirname(pearl_bin))
          FileUtils.mkdir_p(agents_dir)
          File.write(pearl_bin, "#!/bin/bash\n")
          stub_singleton(@handler, :resolve_pearl_bin) { pearl_bin }
          result = @handler.send(:pearl_agents_repo)
          assert_equal tmpdir, result
        end
      end

      # --- discover_agents edge cases ---

      test "discover_agents skips directories without Dockerfile" do
        Dir.mktmpdir do |agents_dir|
          FileUtils.mkdir_p(File.join(agents_dir, "no-dockerfile-agent"))
          File.write(File.join(agents_dir, "no-dockerfile-agent", "README.md"), "hi")
          result = @handler.send(:discover_agents, agents_dir)
          assert_empty result
        end
      end

      test "discover_agents skips base directory even with Dockerfile" do
        Dir.mktmpdir do |agents_dir|
          FileUtils.mkdir_p(File.join(agents_dir, "base"))
          File.write(File.join(agents_dir, "base", "Dockerfile"), "FROM node:22")
          result = @handler.send(:discover_agents, agents_dir)
          assert_empty result
        end
      end

      test "discover_agents returns sorted agents with skill info" do
        Dir.mktmpdir do |agents_dir|
          create_agent_profile(agents_dir, "zebra", skills: false)
          create_agent_profile(agents_dir, "alpha", skills: true)
          result = @handler.send(:discover_agents, agents_dir)
          assert_equal 2, result.size
          assert_equal "alpha", result.first[:name]
          assert result.first[:has_skills]
          assert_equal "zebra", result.last[:name]
          assert_not result.last[:has_skills]
        end
      end

      # --- format_agent ---

      test "format_agent includes skills badge when has_skills is true" do
        result = @handler.send(:format_agent, { name: "code", has_skills: true })
        assert_includes result, "(skills: yes)"
        assert_includes result, "`code`"
      end

      test "format_agent omits skills badge when has_skills is false" do
        result = @handler.send(:format_agent, { name: "pptx", has_skills: false })
        assert_not_includes result, "skills"
        assert_includes result, "`pptx`"
      end

      # --- handle_run error paths ---

      test "handle_run catches Tmux::Error and returns error text" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          stub_singleton(@handler, :request_run_confirmation) { |_| :approved }
          stub_singleton(@tmux, :create_window) do |**_kwargs|
            raise Earl::Tmux::Error, "tmux not available"
          end

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "run", "agent" => "code", "prompt" => "fix tests"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "tmux not available"
        end
      end

      test "validate_agent_exists returns nil when agents_dir is nil" do
        stub_pearl_bin("/usr/local/bin/pearl")
        stub_singleton(@handler, :find_agents_dir) { nil }
        result = @handler.send(:validate_agent_exists, "code")
        assert_nil result
      end

      test "validate_agent_exists returns nil when agent profile exists" do
        with_agents_dir do |agents_dir|
          create_agent_profile(agents_dir, "code", skills: true)
          result = @handler.send(:validate_agent_exists, "code")
          assert_nil result
        end
      end

      # --- status error paths ---

      test "status returns error on Tmux::Error" do
        @tmux.capture_pane_error = Earl::Tmux::Error.new("tmux crashed")
        result = @handler.call("manage_pearl_agents", {
                                 "action" => "status", "target" => "pearl-agents:code-ab12"
                               })
        text = result[:content].first[:text]
        assert_includes text, "tmux crashed"
      end

      test "status log fallback returns error when window name is nil" do
        @tmux.capture_pane_error = Earl::Tmux::NotFound.new("not found")

        Dir.mktmpdir do |tmpdir|
          log_dir = File.join(tmpdir, "pearl-logs")
          FileUtils.mkdir_p(log_dir)
          stub_singleton(@handler, :pearl_log_dir) { log_dir }

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "status", "target" => "pearl-agents"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "not found"
          assert_includes text, "no log file"
        end
      end

      # --- status image detection ---

      test "status detects image paths in output and uploads them" do
        uploaded_refs = []
        stub_singleton(@handler, :detect_and_upload_images) do |result|
          text = result.dig(:content, 0, :text)
          uploaded_refs << text
        end

        @tmux.capture_pane_result = "Generated /tmp/chart.png for review"
        @handler.call("manage_pearl_agents", {
                        "action" => "status", "target" => "pearl-agents:code-ab12"
                      })
        assert_equal 1, uploaded_refs.size
        assert_includes uploaded_refs.first, "/tmp/chart.png"
      end

      test "status handles image upload errors gracefully" do
        stub_singleton(@handler, :upload_context) { raise StandardError, "upload boom" }

        @tmux.capture_pane_result = "Some output"
        result = @handler.call("manage_pearl_agents", {
                                 "action" => "status", "target" => "pearl-agents:code-ab12"
                               })
        text = result[:content].first[:text]
        assert_includes text, "Some output"
      end

      # --- safe_upload_path? ---

      test "safe_upload_path? allows base64 refs" do
        ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
          source: :base64, data: "abc", media_type: "image/png", filename: "img.png"
        )
        assert @handler.send(:safe_upload_path?, ref)
      end

      test "safe_upload_path? allows paths under /tmp" do
        ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
          source: :file_path, data: "/tmp/chart.png", media_type: "image/png", filename: "chart.png"
        )
        assert @handler.send(:safe_upload_path?, ref)
      end

      test "safe_upload_path? allows paths under pearl-images" do
        pearl_path = File.join(Earl.config_root, "pearl-images", "test.png")
        ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
          source: :file_path, data: pearl_path, media_type: "image/png", filename: "test.png"
        )
        assert @handler.send(:safe_upload_path?, ref)
      end

      test "safe_upload_path? rejects paths outside safe dirs" do
        ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
          source: :file_path, data: "/home/user/.ssh/id_rsa", media_type: "image/png", filename: "id_rsa"
        )
        refute @handler.send(:safe_upload_path?, ref)
      end

      test "safe_upload_path? rejects traversal attempts" do
        ref = Earl::ImageSupport::OutputDetector::ImageReference.new(
          source: :file_path, data: "/tmp/../etc/passwd", media_type: "image/png", filename: "passwd"
        )
        refute @handler.send(:safe_upload_path?, ref)
      end

      test "detect_safe_image_refs returns empty for nil text" do
        result = { content: [{ type: "text" }] }
        refs = @handler.send(:detect_safe_image_refs, result)
        assert_empty refs
      end

      test "detect_safe_image_refs returns empty for text with no images" do
        result = { content: [{ type: "text", text: "No images here" }] }
        refs = @handler.send(:detect_safe_image_refs, result)
        assert_empty refs
      end

      test "detect_safe_image_refs deduplicates refs with same path" do
        path = "/tmp/dedup-test-#{SecureRandom.hex(4)}.png"
        File.binwrite(path, "fake png")
        text = "Found image at #{path} and also #{path} again"
        result = { content: [{ type: "text", text: text }] }
        refs = @handler.send(:detect_safe_image_refs, result)
        assert_equal 1, refs.size
        assert_equal path, refs.first.data
      ensure
        File.delete(path) if path && File.exist?(path)
      end

      # --- inbound images ---

      test "tool_definitions includes image_data property" do
        schema = @handler.tool_definitions.first[:inputSchema]
        assert schema[:properties].key?(:image_data), "Expected image_data property in schema"
        assert_equal "array", schema[:properties][:image_data][:type]
      end

      test "write_inbound_images creates directory and writes files" do
        Dir.mktmpdir do |tmpdir|
          Earl.stub(:config_root, tmpdir) do
            images = [
              { "filename" => "chart.png", "base64_data" => Base64.encode64("png data") },
              { "filename" => "photo.jpg", "base64_data" => Base64.encode64("jpg data") }
            ]
            dir = @handler.send(:write_inbound_images, images, "code-ab12")

            assert_equal File.join(tmpdir, "pearl-images", "code-ab12"), dir
            assert_equal "png data", File.binread(File.join(dir, "chart.png"))
            assert_equal "jpg data", File.binread(File.join(dir, "photo.jpg"))
          end
        end
      end

      test "write_inbound_images returns nil for empty array" do
        result = @handler.send(:write_inbound_images, [], "code-ab12")
        assert_nil result
      end

      test "write_inbound_images returns nil for nil input" do
        result = @handler.send(:write_inbound_images, nil, "code-ab12")
        assert_nil result
      end

      test "write_inbound_images uses default filename when missing" do
        Dir.mktmpdir do |tmpdir|
          Earl.stub(:config_root, tmpdir) do
            images = [{ "base64_data" => Base64.encode64("data") }]
            dir = @handler.send(:write_inbound_images, images, "code-ab12")
            assert File.exist?(File.join(dir, "image.png"))
          end
        end
      end

      test "write_inbound_images returns nil on error" do
        stub_singleton(@handler, :write_single_image) { |_dir, _img| raise Errno::ENOSPC, "disk full" }
        Dir.mktmpdir do |tmpdir|
          Earl.stub(:config_root, tmpdir) do
            images = [{ "filename" => "a.png", "base64_data" => Base64.encode64("data") }]
            result = @handler.send(:write_inbound_images, images, "code-ab12")
            assert_nil result
          end
        end
      end

      # --- file_ids support ---

      test "tool_definitions includes file_ids property" do
        schema = @handler.tool_definitions.first[:inputSchema]
        assert schema[:properties].key?(:file_ids), "Expected file_ids property in schema"
        assert_equal "array", schema[:properties][:file_ids][:type]
      end

      test "resolve_image_data prefers explicit image_data over file_ids" do
        images = [{ "filename" => "a.png", "base64_data" => "abc" }]
        args = { "image_data" => images, "file_ids" => ["fid-1"] }
        result = @handler.send(:resolve_image_data, args)
        assert_equal images, result
      end

      test "resolve_image_data downloads from Mattermost when no image_data" do
        api = Object.new
        info_body = JSON.generate({ "name" => "photo.png", "mime_type" => "image/png" })
        file_body = "raw png bytes"
        stub_singleton(api, :get) do |path|
          response = Object.new
          body = path.end_with?("/info") ? info_body : file_body
          stub_singleton(response, :body) { body }
          stub_singleton(response, :is_a?) do |klass|
            klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: api, tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        result = handler.send(:resolve_image_data, { "file_ids" => ["fid-1"] })

        assert_equal 1, result.size
        assert_equal "photo.png", result.first["filename"]
        assert_equal Base64.strict_encode64("raw png bytes"), result.first["base64_data"]
        assert_equal "image/png", result.first["media_type"]
      end

      test "resolve_image_data returns empty array when neither provided" do
        result = @handler.send(:resolve_image_data, {})
        assert_equal [], result
      end

      test "download_single_file returns nil when info request fails" do
        result = @handler.send(:download_single_file, "bad-fid")
        assert_nil result
      end

      test "download_single_file returns nil when data request fails" do
        api = Object.new
        call_count = 0
        stub_singleton(api, :get) do |_path|
          call_count += 1
          response = Object.new
          if call_count == 1
            stub_singleton(response, :body) { '{"name":"x.png","mime_type":"image/png"}' }
            stub_singleton(response, :is_a?) do |klass|
              klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
            end
          else
            stub_singleton(response, :is_a?) { |_klass| false }
          end
          response
        end
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: api, tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        result = handler.send(:download_single_file, "fid-1")
        assert_nil result
      end

      test "build_file_data uses defaults when name and mime_type are nil" do
        result = @handler.send(:build_file_data, {}, "raw bytes")
        assert_equal "image.png", result["filename"]
        assert_equal "image/png", result["media_type"]
        assert_equal Base64.strict_encode64("raw bytes"), result["base64_data"]
      end

      test "download_single_file returns nil on JSON parse error" do
        api = Object.new
        stub_singleton(api, :get) do |_path|
          response = Object.new
          stub_singleton(response, :body) { "not json" }
          stub_singleton(response, :is_a?) do |klass|
            klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: api, tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        result = handler.send(:download_single_file, "fid-1")
        assert_nil result
      end

      # --- ApiClientAdapter ---

      test "ApiClientAdapter upload_file delegates to api post_multipart" do
        uploaded = []
        api = Object.new
        stub_singleton(api, :post_multipart) do |path, upload|
          uploaded << { path: path, upload: upload }
          response = Object.new
          stub_singleton(response, :body) { '{"file_infos":[{"id":"f1"}]}' }
          stub_singleton(response, :is_a?) do |klass|
            klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end

        adapter = Earl::Mcp::PearlHandler::ApiClientAdapter.new(api)
        result = adapter.upload_file("fake-upload")

        assert_equal 1, uploaded.size
        assert_equal "/files", uploaded.first[:path]
        assert_equal "f1", result.dig("file_infos", 0, "id")
      end

      test "ApiClientAdapter create_post_with_files delegates to api post" do
        posted = []
        api = Object.new
        stub_singleton(api, :post) do |path, body|
          posted << { path: path, body: body }
          response = Object.new
          stub_singleton(response, :body) { '{"id":"post-1"}' }
          stub_singleton(response, :is_a?) do |klass|
            klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end

        adapter = Earl::Mcp::PearlHandler::ApiClientAdapter.new(api)
        file_post = Earl::Mattermost::FileHandling::FilePost.new(
          channel_id: "ch-1", message: "", root_id: "t-1", file_ids: %w[f1]
        )
        result = adapter.create_post_with_files(file_post)

        assert_equal 1, posted.size
        assert_equal "/posts", posted.first[:path]
        assert_equal "post-1", result["id"]
      end

      test "ApiClientAdapter returns empty hash on non-success response" do
        api = Object.new
        stub_singleton(api, :post_multipart) do |_path, _upload|
          response = Object.new
          stub_singleton(response, :code) { "403" }
          stub_singleton(response, :is_a?) do |klass|
            Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end

        adapter = Earl::Mcp::PearlHandler::ApiClientAdapter.new(api)
        result = adapter.upload_file("fake-upload")
        assert_equal({}, result)
      end

      test "ApiClientAdapter returns empty hash on JSON parse error" do
        api = Object.new
        stub_singleton(api, :post_multipart) do |_path, _upload|
          response = Object.new
          stub_singleton(response, :body) { "not json" }
          stub_singleton(response, :is_a?) do |klass|
            klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end

        adapter = Earl::Mcp::PearlHandler::ApiClientAdapter.new(api)
        result = adapter.upload_file("fake-upload")
        assert_equal({}, result)
      end

      # --- WebSocket / confirmation edge cases ---

      test "connect_websocket returns nil on SocketError" do
        mock_ws_module = Module.new do
          def self.connect(_url)
            raise SocketError, "getaddrinfo failed"
          end
        end
        ws_const = WebSocket::Client::Simple
        WebSocket::Client.send(:remove_const, :Simple)
        WebSocket::Client.const_set(:Simple, mock_ws_module)
        begin
          result = @handler.send(:connect_websocket)
          assert_nil result
        ensure
          WebSocket::Client.send(:remove_const, :Simple)
          WebSocket::Client.const_set(:Simple, ws_const)
        end
      end

      test "close_websocket handles nil websocket" do
        assert_nothing_raised do
          @handler.send(:close_websocket, nil)
        end
      end

      test "close_websocket handles IOError during close" do
        ws = Object.new
        stub_singleton(ws, :close) { raise IOError, "broken" }
        assert_nothing_raised do
          @handler.send(:close_websocket, ws)
        end
      end

      test "parse_reaction_event returns nil for empty data" do
        msg = Object.new
        stub_singleton(msg, :data) { "" }
        result = @handler.send(:parse_reaction_event, msg)
        assert_nil result
      end

      test "parse_reaction_event returns nil for nil data" do
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
        stub_singleton(msg, :data) { "not valid json" }
        result = @handler.send(:parse_reaction_event, msg)
        assert_nil result
      end

      test "parse_reaction_event returns reaction data for reaction_added events" do
        reaction = JSON.generate({ "post_id" => "p1", "emoji_name" => "+1" })
        msg = Object.new
        event = JSON.generate({ "event" => "reaction_added", "data" => { "reaction" => reaction } })
        stub_singleton(msg, :data) { event }
        result = @handler.send(:parse_reaction_event, msg)
        assert_equal "p1", result["post_id"]
      end

      test "parse_reaction_event handles nil nested reaction" do
        msg = Object.new
        event = JSON.generate({ "event" => "reaction_added", "data" => {} })
        stub_singleton(msg, :data) { event }
        result = @handler.send(:parse_reaction_event, msg)
        assert_equal({}, result)
      end

      test "enqueue_reaction swallows errors" do
        handler = build_handler_with_api(post_success: true)
        ctx = Object.new
        stub_singleton(ctx, :enqueue) { |_| raise StandardError, "boom" }
        msg = Object.new
        assert_nothing_raised do
          handler.send(:enqueue_reaction, ctx, msg)
        end
      end

      test "wait_for_confirmation returns error on unexpected exception" do
        stub_singleton(@handler, :connect_websocket) do
          raise StandardError, "unexpected"
        end
        result = @handler.send(:wait_for_confirmation, "post-123")
        assert_equal :error, result
      end

      # --- classify_reaction edge cases ---

      test "classify_reaction ignores unrecognized emoji" do
        handler = build_handler_with_api(post_success: true)
        reaction = { "user_id" => "user-42", "emoji_name" => "heart" }
        result = handler.send(:classify_reaction, reaction)
        assert_nil result
      end

      test "classify_reaction returns approved for white_check_mark" do
        handler = build_handler_with_api(post_success: true)
        reaction = { "user_id" => "user-42", "emoji_name" => "white_check_mark" }
        result = handler.send(:classify_reaction, reaction)
        assert_equal :approved, result
      end

      test "allowed_reactor returns true when allowed_users is empty" do
        handler = build_handler_with_api(post_success: true, allowed_users: [])
        result = handler.send(:allowed_reactor?, "any-user")
        assert result
      end

      test "allowed_reactor returns true when user is in allowed list" do
        handler = build_handler_with_api(post_success: true, allowed_users: %w[alice])
        result = handler.send(:allowed_reactor?, "alice-uid")
        assert result
      end

      test "allowed_reactor returns false when user is not in allowed list" do
        handler = build_handler_with_api(post_success: true, allowed_users: %w[alice])
        result = handler.send(:allowed_reactor?, "bob-uid")
        assert_not result
      end

      test "allowed_reactor returns false when API call fails" do
        config = build_mock_config(allowed_users: %w[alice])
        api = Object.new
        stub_singleton(api, :post) { |_path, _body| nil }
        stub_singleton(api, :delete) { |_path| nil }
        stub_singleton(api, :get) do |_path|
          response = Object.new
          stub_singleton(response, :body) { "{}" }
          stub_singleton(response, :is_a?) do |klass|
            Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end
        handler = Earl::Mcp::PearlHandler.new(
          config: config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        result = handler.send(:allowed_reactor?, "user-1")
        assert_not result
      end

      # --- add_reaction_options error paths ---

      test "add_reaction_options logs warning on reaction failure" do
        api = Object.new
        stub_singleton(api, :post) do |_path, _body|
          response = Object.new
          stub_singleton(response, :is_a?) do |klass|
            Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end
        stub_singleton(api, :delete) { |_path| nil }
        stub_singleton(api, :get) { |_path| nil }
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        assert_nothing_raised do
          handler.send(:add_reaction_options, "post-1")
        end
      end

      test "add_reaction_options handles IOError" do
        api = Object.new
        stub_singleton(api, :post) { |_path, _body| raise IOError, "connection reset" }
        stub_singleton(api, :delete) { |_path| nil }
        stub_singleton(api, :get) { |_path| nil }
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        assert_nothing_raised do
          handler.send(:add_reaction_options, "post-1")
        end
      end

      test "delete_confirmation_post handles errors gracefully" do
        api = Object.new
        stub_singleton(api, :post) { |_path, _body| nil }
        stub_singleton(api, :delete) { |_path| raise StandardError, "delete failed" }
        stub_singleton(api, :get) { |_path| nil }
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        assert_nothing_raised do
          handler.send(:delete_confirmation_post, "post-1")
        end
      end

      # --- post_confirmation_request error paths ---

      test "post_confirmation_request returns nil on IOError" do
        api = Object.new
        stub_singleton(api, :post) { |_path, _body| raise IOError, "broken pipe" }
        stub_singleton(api, :delete) { |_path| nil }
        stub_singleton(api, :get) { |_path| nil }
        handler = Earl::Mcp::PearlHandler.new(
          config: @config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "hi", window_name: "code-ab12",
          log_path: "/tmp/code-ab12.log", image_dir: nil
        )
        result = handler.send(:post_confirmation_request, request)
        assert_nil result
      end

      # --- MessageHandlerContext ---

      test "MessageHandlerContext enqueue ignores non-matching post_id" do
        queue = Queue.new
        extractor = ->(msg) { { "post_id" => "other", "emoji_name" => msg } }
        ctx = Earl::Mcp::PearlHandler::MessageHandlerContext.new(
          ws: nil, post_id: "target-post", extractor: extractor, queue: queue
        )
        ctx.enqueue("+1")
        assert queue.empty?
      end

      test "MessageHandlerContext enqueue pushes matching post_id" do
        queue = Queue.new
        extractor = ->(msg) { { "post_id" => "target-post", "emoji_name" => msg } }
        ctx = Earl::Mcp::PearlHandler::MessageHandlerContext.new(
          ws: nil, post_id: "target-post", extractor: extractor, queue: queue
        )
        ctx.enqueue("+1")
        assert_equal 1, queue.size
      end

      test "MessageHandlerContext enqueue ignores nil reaction_data" do
        queue = Queue.new
        extractor = ->(_msg) {}
        ctx = Earl::Mcp::PearlHandler::MessageHandlerContext.new(
          ws: nil, post_id: "target-post", extractor: extractor, queue: queue
        )
        ctx.enqueue("anything")
        assert queue.empty?
      end

      # --- Mock helpers ---

      private

      class MockTmuxAdapter
        attr_accessor :session_exists_result, :capture_pane_result, :capture_pane_error
        attr_reader :created_sessions, :created_windows

        def initialize
          @session_exists_result = false
          @created_sessions = []
          @created_windows = []
          @capture_pane_result = nil
          @capture_pane_error = nil
        end

        def session_exists?(_name) = @session_exists_result

        def create_session(name:, command: nil, working_dir: nil)
          @created_sessions << { name: name, command: command, working_dir: working_dir }
        end

        def create_window(session:, name: nil, command: nil, working_dir: nil)
          @created_windows << { session: session, name: name, command: command, working_dir: working_dir }
        end

        def capture_pane(target, lines: 100)
          raise @capture_pane_error if @capture_pane_error

          @capture_pane_result || "output for #{target} (#{lines} lines)"
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
        def post(_path, _body) = nil
        def get(_path) = nil
        def delete(_path) = nil
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

      def stub_pearl_bin(path)
        stub_singleton(@handler, :resolve_pearl_bin) { path }
      end

      def with_agents_dir
        Dir.mktmpdir do |tmpdir|
          bin_dir = File.join(tmpdir, "bin")
          agents_dir = File.join(tmpdir, "agents")
          FileUtils.mkdir_p(bin_dir)
          FileUtils.mkdir_p(agents_dir)
          pearl_bin = File.join(bin_dir, "pearl")
          File.write(pearl_bin, "#!/bin/bash\n")
          stub_pearl_bin(pearl_bin)
          yield agents_dir
        end
      end

      def create_agent_profile(agents_dir, name, skills: false)
        agent_dir = File.join(agents_dir, name)
        FileUtils.mkdir_p(agent_dir)
        File.write(File.join(agent_dir, "Dockerfile"), "FROM pearl-base:latest")
        return unless skills

        skills_dir = File.join(agent_dir, "skills")
        FileUtils.mkdir_p(skills_dir)
        File.write(File.join(skills_dir, "CLAUDE.md"), "# Agent")
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
          username = path.include?("alice-uid") ? "alice" : "bob"
          uname = username
          stub_singleton(response, :body) { JSON.generate({ "id" => "user-1", "username" => uname }) }
          stub_singleton(response, :is_a?) do |klass|
            klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
          end
          response
        end

        handler = Earl::Mcp::PearlHandler.new(
          config: config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )

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
        stub_singleton(ws, :send) { |*_args, **_kwargs| nil }
        stub_singleton(ws, :fire_message) do |data, type: :text|
          handler = @handlers[:message]
          return unless handler

          msg_type = type
          msg = Object.new
          stub_singleton(msg, :type) { msg_type }
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
