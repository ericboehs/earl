# frozen_string_literal: true

require "test_helper"

module Earl
  module Mcp
    class ConversationHandlerTest < Minitest::Test
      setup do
        @api = build_mock_api
        @handler = Earl::Mcp::ConversationHandler.new(api_client: @api)
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

      test "call returns error for invalid analysis_type" do
        result = @handler.call("analyze_conversation", {
                                 "thread_id" => "abc123",
                                 "analysis_type" => "invalid"
                               })
        text = result[:content].first[:text]
        assert_includes text, "unknown analysis_type"
        assert_includes text, "invalid"
      end

      test "call returns nil for unknown tool name" do
        result = @handler.call("unknown_tool", {})
        assert_nil result
      end

      # --- transcript formatting ---

      test "fetch_and_format_transcript formats posts oldest first" do
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_mock_claude(api, "Analysis result")

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        text = result[:content].first[:text]
        assert_equal "Analysis result", text
      end

      test "fetch_and_format_transcript returns message when no posts found" do
        api = build_mock_api(thread_response: failed_response)
        handler = build_handler_with_mock_claude(api, "No posts analysis")

        result = handler.call("analyze_conversation", { "thread_id" => "missing" })
        assert result[:content].first[:text]
      end

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
        handler.call("analyze_conversation", { "thread_id" => "root123" })

        assert_includes transcript, "[Transcript truncated"
        assert transcript.length < 60_000
      end

      # --- analysis prompt ---

      test "build_analysis_prompt uses correct type" do
        api = build_mock_api(thread_response: sample_thread_response)

        prompt_used = nil
        handler = build_handler_capturing_prompt(api) { |p, _t| prompt_used = p }
        handler.call("analyze_conversation", {
                       "thread_id" => "root123",
                       "analysis_type" => "troubleshooting"
                     })

        assert_includes prompt_used, "troubleshooting"
      end

      test "build_analysis_prompt appends focus when provided" do
        api = build_mock_api(thread_response: sample_thread_response)

        prompt_used = nil
        handler = build_handler_capturing_prompt(api) { |p, _t| prompt_used = p }
        handler.call("analyze_conversation", {
                       "thread_id" => "root123",
                       "focus" => "error handling"
                     })

        assert_includes prompt_used, "Focus specifically on: error handling"
      end

      test "build_analysis_prompt omits focus line when not provided" do
        api = build_mock_api(thread_response: sample_thread_response)

        prompt_used = nil
        handler = build_handler_capturing_prompt(api) { |p, _t| prompt_used = p }
        handler.call("analyze_conversation", { "thread_id" => "root123" })

        assert_not_includes prompt_used, "Focus specifically on:"
      end

      test "defaults to general analysis type" do
        api = build_mock_api(thread_response: sample_thread_response)

        prompt_used = nil
        handler = build_handler_capturing_prompt(api) { |p, _t| prompt_used = p }
        handler.call("analyze_conversation", { "thread_id" => "root123" })

        expected = Earl::Mcp::ConversationHandler::AnalysisPrompt::PROMPTS["general"]
        assert_includes prompt_used, expected
      end

      # --- subprocess ---

      test "returns analysis text on success" do
        api = build_mock_api(thread_response: sample_thread_response)
        handler = build_handler_with_mock_claude(api, "Great analysis")

        result = handler.call("analyze_conversation", { "thread_id" => "root123" })
        assert_equal "Great analysis", result[:content].first[:text]
      end

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

      # --- all analysis types valid ---

      test "all analysis types have corresponding prompts" do
        types = Earl::Mcp::ConversationHandler::AnalysisPrompt::ANALYSIS_TYPES
        prompts = Earl::Mcp::ConversationHandler::AnalysisPrompt::PROMPTS

        types.each do |type|
          assert prompts.key?(type), "Missing prompt for analysis type: #{type}"
          assert_not prompts[type].empty?, "Empty prompt for analysis type: #{type}"
        end
      end

      private

      def build_mock_api(thread_response: nil)
        api = Object.new
        resp = thread_response || failed_response
        api.define_singleton_method(:get) { |_path| resp }
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
        handler = Earl::Mcp::ConversationHandler.new(api_client: api)
        status = build_exit_status(0)
        handler.define_singleton_method(:execute_claude) { |_prompt| [output, status] }
        handler
      end

      def build_handler_with_failed_claude(api, exit_status:)
        handler = Earl::Mcp::ConversationHandler.new(api_client: api)
        status = build_exit_status(exit_status)
        handler.define_singleton_method(:execute_claude) { |_prompt| ["", status] }
        handler
      end

      def build_handler_with_timeout(api)
        handler = Earl::Mcp::ConversationHandler.new(api_client: api)
        handler.define_singleton_method(:execute_claude) { |_prompt| raise Timeout::Error, "execution expired" }
        handler
      end

      def build_handler_capturing_prompt(api, &block)
        handler = Earl::Mcp::ConversationHandler.new(api_client: api)
        status = build_exit_status(0)
        handler.define_singleton_method(:run_analysis) do |prompt, transcript|
          block.call(prompt, transcript)
          "mocked analysis"
        end
        handler.define_singleton_method(:execute_claude) { |_prompt| ["mocked", status] }
        handler
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
