# frozen_string_literal: true

require "test_helper"

module Earl
  module Mcp
    class ConversationDiagnoserTest < Minitest::Test
      setup do
        @config = build_mock_config
        @api = build_mock_api
        @handler = Earl::Mcp::ConversationDiagnoser.new(config: @config, api_client: @api)
      end

      teardown do
        ENV.delete("PLATFORM_TEAM_NAME")
      end

      # --- tool_definitions ---

      test "tool_definitions returns one tool" do
        defs = @handler.tool_definitions
        assert_equal 1, defs.size
        assert_equal "analyze_conversation", defs.first[:name]
      end

      test "tool_definitions includes inputSchema with required thread_id" do
        schema = @handler.tool_definitions.first[:inputSchema]
        assert_equal "object", schema[:type]
        assert_includes schema[:required], "thread_id"
      end

      test "tool_definitions does not include analysis_type property" do
        props = @handler.tool_definitions.first[:inputSchema][:properties]
        assert_not_includes props.keys, :analysis_type
      end

      test "tool_definitions includes focus property" do
        props = @handler.tool_definitions.first[:inputSchema][:properties]
        assert_includes props.keys, :focus
      end

      # --- handles? ---

      test "handles? returns true for analyze_conversation" do
        assert @handler.handles?("analyze_conversation")
      end

      test "handles? returns false for other tools" do
        assert_not @handler.handles?("save_memory")
        assert_not @handler.handles?("permission_prompt")
      end

      # --- validation ---

      test "call returns error when thread_id is missing" do
        result = @handler.call("analyze_conversation", {})
        assert_includes result[:content].first[:text], "thread_id is required"
      end

      test "call returns error when thread_id is empty" do
        result = @handler.call("analyze_conversation", { "thread_id" => "" })
        assert_includes result[:content].first[:text], "thread_id is required"
      end

      test "call returns nil for unknown tool name" do
        result = @handler.call("unknown_tool", {})
        assert_nil result
      end

      # --- analysis prompt ---

      test "build_analysis_prompt uses EARL diagnostic prompt" do
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_capturing_prompt(api) { |p, _t| @captured_prompt = p }
        stub_approval(handler, :denied)

        handler.call("analyze_conversation", { "thread_id" => "root123" })

        assert_includes @captured_prompt, "EARL"
        assert_includes @captured_prompt, "Errors"
        assert_includes @captured_prompt, "PART 1"
        assert_includes @captured_prompt, "PART 2"
      end

      test "build_analysis_prompt appends focus when provided" do
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_capturing_prompt(api) { |p, _t| @captured_prompt = p }
        stub_approval(handler, :denied)

        handler.call("analyze_conversation", {
                       "thread_id" => "root123",
                       "focus" => "error handling"
                     })

        assert_includes @captured_prompt, "Focus specifically on: error handling"
      end

      test "build_analysis_prompt omits focus line when not provided" do
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_capturing_prompt(api) { |p, _t| @captured_prompt = p }
        stub_approval(handler, :denied)

        handler.call("analyze_conversation", { "thread_id" => "root123" })

        assert_not_includes @captured_prompt, "Focus specifically on:"
      end

      # --- transcript formatting ---

      test "transcript labels bot posts as EARL" do
        posts = {
          "p1" => { "id" => "p1", "create_at" => 1_000_000, "message" => "hello",
                    "user_id" => "u1", "props" => {} },
          "p2" => { "id" => "p2", "create_at" => 2_000_000, "message" => "hi back",
                    "user_id" => "bot1", "props" => { "from_bot" => "true" } }
        }
        thread_data = { "posts" => posts, "order" => %w[p1 p2] }
        api = build_mock_api(thread_response: success_response(thread_data))

        transcript = nil
        handler = build_handler_capturing_prompt(api) { |_prompt, t| transcript = t }
        stub_approval(handler, :denied)
        handler.call("analyze_conversation", { "thread_id" => "root123" })

        assert_includes transcript, "User: hello"
        assert_includes transcript, "EARL: hi back"
      end

      test "transcript truncates at max chars" do
        long_message = "x" * 60_000
        posts = {
          "p1" => { "id" => "p1", "create_at" => 1_000_000, "message" => long_message,
                    "user_id" => "u1", "props" => {} }
        }
        thread_data = { "posts" => posts, "order" => %w[p1] }
        api = build_mock_api(thread_response: success_response(thread_data))

        transcript = nil
        handler = build_handler_capturing_prompt(api) { |_prompt, t| transcript = t }
        stub_approval(handler, :denied)
        handler.call("analyze_conversation", { "thread_id" => "root123" })

        assert_includes transcript, "[Transcript truncated"
        assert transcript.length < 60_000
      end

      # --- analysis output splitting ---

      test "splits analysis output on --- separator" do
        analysis = "PART 1 analysis\n\n---\n\nTitle: Bug\nLabels: bug\nBody: Fix it"
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_mock_claude(api, analysis)
        stub_approval(handler, :denied)

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        text = result[:content].first[:text]

        assert_includes text, "PART 1 analysis"
        assert_includes text, "Issue creation skipped"
      end

      test "handles analysis without separator gracefully" do
        analysis = "Just some analysis without a separator"
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_mock_claude(api, analysis)
        stub_approval(handler, :denied)

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        text = result[:content].first[:text]

        assert_includes text, "Just some analysis without a separator"
      end

      # --- subprocess ---

      test "returns error on non-zero exit" do
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_failed_claude(api, exit_status: 1)

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        assert_includes result[:content].first[:text], "Error: claude exited with status 1"
      end

      test "returns error on empty output" do
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_mock_claude(api, "   ")

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        assert_includes result[:content].first[:text], "Error: claude returned empty output"
      end

      test "returns error on timeout" do
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_timeout(api)

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        assert_includes result[:content].first[:text], "timed out"
      end

      # --- issue approval flow ---

      test "approved flow includes issue URL in result" do
        analysis = "Analysis text\n\n---\n\nTitle: Fix bug\nLabels: bug\nBody: EARL fails"
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_mock_claude(api, analysis)
        stub_approval(handler, :approved)
        stub_issue_create(handler, "https://github.com/ericboehs/earl/issues/42")

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        text = result[:content].first[:text]

        assert_includes text, "Analysis text"
        assert_includes text, "GitHub issue created"
        assert_includes text, "issues/42"
      end

      test "denied flow skips issue creation" do
        analysis = "Analysis text\n\n---\n\nTitle: Fix bug\nLabels: bug\nBody: EARL fails"
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_mock_claude(api, analysis)
        stub_approval(handler, :denied)

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        text = result[:content].first[:text]

        assert_includes text, "Analysis text"
        assert_includes text, "Issue creation skipped"
        assert_not_includes text, "GitHub issue created"
      end

      test "error flow shows warning" do
        analysis = "Analysis text\n\n---\n\nTitle: Fix bug\nLabels: bug\nBody: EARL fails"
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_mock_claude(api, analysis)
        stub_approval(handler, :error)

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        text = result[:content].first[:text]

        assert_includes text, "Analysis text"
        assert_includes text, "Could not request approval"
      end

      # --- GitHub issue creation ---

      test "parse_issue_parts extracts title labels and body" do
        input = "Title: Fix the bug\nLabels: enhancement\nBody: EARL should handle this better."
        handler = build_handler_for_parsing
        title, labels, body = handler.send(:parse_issue_parts, input)

        assert_equal "Fix the bug", title
        assert_equal "enhancement", labels
        assert_equal "EARL should handle this better.", body
      end

      test "parse_issue_parts defaults labels to bug" do
        input = "Title: Fix it\nBody: Something broke."
        handler = build_handler_for_parsing
        _title, labels, _body = handler.send(:parse_issue_parts, input)

        assert_equal "bug", labels
      end

      test "parse_issue_parts returns nil title when missing" do
        input = "No structured content here"
        handler = build_handler_for_parsing
        title, _labels, _body = handler.send(:parse_issue_parts, input)

        assert_nil title
      end

      # --- thread URL building ---

      test "build_thread_url constructs Mattermost permalink" do
        handler = build_handler_for_parsing
        url = handler.send(:build_thread_url, "abc123")

        assert_equal "https://mm.example.com/myteam/pl/abc123", url
      end

      private

      def build_mock_config
        config = Object.new
        config.define_singleton_method(:platform_url) { "https://mm.example.com" }
        config.define_singleton_method(:platform_token) { "test-token" }
        config.define_singleton_method(:platform_channel_id) { "chan123" }
        config.define_singleton_method(:platform_thread_id) { "thread456" }
        config.define_singleton_method(:platform_bot_id) { "bot789" }
        config.define_singleton_method(:websocket_url) { "wss://mm.example.com/api/v4/websocket" }
        config.define_singleton_method(:allowed_users) { [] }
        config.define_singleton_method(:permission_timeout_ms) { 86_400_000 }
        config
      end

      def build_mock_api(thread_response: nil)
        api = Object.new
        resp = thread_response || failed_response
        api.define_singleton_method(:get) { |_path| resp }
        api.define_singleton_method(:post) { |_path, _body| resp }
        api
      end

      def success_response(data)
        response = Object.new
        body = JSON.generate(data)
        response.define_singleton_method(:body) { body }
        response.define_singleton_method(:is_a?) { |klass| klass == Net::HTTPSuccess || super(klass) }
        response
      end

      def failed_response
        response = Object.new
        response.define_singleton_method(:is_a?) { |_klass| false }
        response
      end

      def sample_thread_response
        posts = {
          "p1" => { "id" => "p1", "create_at" => 1_000_000, "message" => "Help me",
                    "user_id" => "u1", "props" => {} },
          "p2" => { "id" => "p2", "create_at" => 2_000_000, "message" => "Sure thing",
                    "user_id" => "bot1", "props" => { "from_bot" => "true" } }
        }
        success_response({ "posts" => posts, "order" => %w[p1 p2] })
      end

      def build_handler_with_mock_claude(api, output)
        handler = Earl::Mcp::ConversationDiagnoser.new(config: @config, api_client: api)
        status = build_exit_status(0)
        handler.define_singleton_method(:execute_claude) { |_prompt| [output, status] }
        handler
      end

      def build_handler_with_failed_claude(api, exit_status:)
        handler = Earl::Mcp::ConversationDiagnoser.new(config: @config, api_client: api)
        status = build_exit_status(exit_status)
        handler.define_singleton_method(:execute_claude) { |_prompt| ["", status] }
        handler
      end

      def build_handler_with_timeout(api)
        handler = Earl::Mcp::ConversationDiagnoser.new(config: @config, api_client: api)
        handler.define_singleton_method(:execute_claude) { |_prompt| raise Timeout::Error, "execution expired" }
        handler
      end

      def build_handler_capturing_prompt(api, &block)
        handler = Earl::Mcp::ConversationDiagnoser.new(config: @config, api_client: api)
        status = build_exit_status(0)
        handler.define_singleton_method(:run_analysis) do |prompt, transcript|
          block.call(prompt, transcript)
          "mocked analysis\n\n---\n\nTitle: Test\nLabels: bug\nBody: Test body"
        end
        handler.define_singleton_method(:execute_claude) { |_prompt| ["mocked", status] }
        handler
      end

      def build_handler_for_parsing
        ENV["PLATFORM_TEAM_NAME"] = "myteam"
        Earl::Mcp::ConversationDiagnoser.new(config: @config, api_client: @api)
      end

      def stub_approval(handler, decision)
        handler.define_singleton_method(:request_issue_approval) { |_text, _tid| decision }
      end

      def stub_issue_create(handler, url)
        handler.define_singleton_method(:create_github_issue) { |_body, _thread_url| url }
      end

      def build_exit_status(code)
        status = Object.new
        status.define_singleton_method(:success?) { code.zero? }
        status.define_singleton_method(:exitstatus) { code }
        status
      end
    end
  end
end
