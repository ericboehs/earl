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
          @handler.define_singleton_method(:request_run_confirmation) { |_| :approved }

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
          @handler.define_singleton_method(:request_run_confirmation) { |_| :approved }

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
          @handler.define_singleton_method(:request_run_confirmation) { |_| :approved }

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
          @handler.define_singleton_method(:request_run_confirmation) { |_| :denied }

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
          @handler.define_singleton_method(:request_run_confirmation) { |_| :error }

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
          @handler.define_singleton_method(:request_run_confirmation) { |_| :approved }

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
          @handler.define_singleton_method(:request_run_confirmation) { |_| :approved }

          result = @handler.call("manage_pearl_agents", {
                                   "action" => "run", "agent" => "code", "prompt" => "fix tests"
                                 })
          text = result[:content].first[:text]
          assert_includes text, "manage_tmux_sessions"
          assert_includes text, "Monitor"
        end
      end

      # --- confirmation flow ---

      test "post_confirmation_request posts to correct channel and thread" do
        handler = build_handler_with_api(post_success: true)
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "fix tests", window_name: "code-ab12"
        )
        post_id = handler.send(:post_confirmation_request, request)
        assert_equal "spawn-post-1", post_id
      end

      test "post_confirmation_request returns nil when API fails" do
        handler = build_handler_with_api(post_success: false)
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "fix tests", window_name: "code-ab12"
        )
        post_id = handler.send(:post_confirmation_request, request)
        assert_nil post_id
      end

      test "confirmation message includes agent and prompt" do
        handler = build_handler_with_api(post_success: true)
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "fix tests", window_name: "code-ab12"
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
        @handler.define_singleton_method(:connect_websocket) { nil }
        result = @handler.send(:wait_for_confirmation, "post-123")
        assert_equal :error, result
      end

      test "polling responds to ping frames with pong" do
        handler = build_handler_with_api(post_success: true)
        mock_ws = build_mock_websocket

        pong_sent = false
        mock_ws.define_singleton_method(:send) do |_data, **kwargs|
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
          agent: "code", prompt: "hi", window_name: "code-ab12"
        )
        result = handler.send(:request_run_confirmation, request)
        assert_equal :error, result
      end

      # --- RunRequest ---

      test "RunRequest target returns session:window format" do
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "hello", window_name: "code-ab12"
        )
        assert_equal "pearl-agents:code-ab12", request.target
      end

      test "RunRequest pearl_command builds correct command" do
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "fix the bug", window_name: "code-ab12"
        )
        command = request.pearl_command("/usr/local/bin/pearl")
        assert_includes command, "/usr/local/bin/pearl"
        assert_includes command, "code"
        assert_includes command, "-p"
        assert_includes command, "fix\\ the\\ bug"
      end

      test "RunRequest pearl_command escapes pearl_bin path" do
        request = Earl::Mcp::PearlHandler::RunRequest.new(
          agent: "code", prompt: "hello", window_name: "code-ab12"
        )
        command = request.pearl_command("/path with spaces/pearl")
        assert_includes command, '/path\\ with\\ spaces/pearl'
      end

      # --- Mock helpers ---

      private

      class MockTmuxAdapter
        attr_accessor :session_exists_result
        attr_reader :created_sessions, :created_windows

        def initialize
          @session_exists_result = false
          @created_sessions = []
          @created_windows = []
        end

        def session_exists?(_name) = @session_exists_result

        def create_session(name:, command: nil, working_dir: nil)
          @created_sessions << { name: name, command: command, working_dir: working_dir }
        end

        def create_window(session:, name: nil, command: nil, working_dir: nil)
          @created_windows << { session: session, name: name, command: command, working_dir: working_dir }
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
        config.define_singleton_method(:platform_channel_id) { "channel-123" }
        config.define_singleton_method(:platform_thread_id) { "thread-123" }
        config.define_singleton_method(:platform_bot_id) { "bot-123" }
        config.define_singleton_method(:permission_timeout_ms) { 120_000 }
        config.define_singleton_method(:websocket_url) { "wss://mm.example.com/api/v4/websocket" }
        config.define_singleton_method(:platform_token) { "mock-token" }
        config.define_singleton_method(:allowed_users) { users }
        config
      end

      def stub_pearl_bin(path)
        @handler.define_singleton_method(:resolve_pearl_bin) { path }
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
          api.define_singleton_method(:post) do |path, body|
            psts << { path: path, body: body }
            response = Object.new
            response.define_singleton_method(:body) { JSON.generate({ "id" => "spawn-post-1" }) }
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

        handler = Earl::Mcp::PearlHandler.new(
          config: config, api_client: api,
          tmux_store: @tmux_store, tmux_adapter: @tmux
        )

        handler.define_singleton_method(:dequeue_reaction) do |queue|
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
        ws.define_singleton_method(:on) do |event, &block|
          @handlers[event] = block
        end
        ws.define_singleton_method(:close) {}
        ws.define_singleton_method(:send) { |*_args, **_kwargs| nil }
        ws.define_singleton_method(:fire_message) do |data, type: :text|
          handler = @handlers[:message]
          return unless handler

          msg_type = type
          msg = Object.new
          msg.define_singleton_method(:type) { msg_type }
          msg.define_singleton_method(:data) { data }
          msg.define_singleton_method(:empty?) { data.nil? || data.empty? }
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
