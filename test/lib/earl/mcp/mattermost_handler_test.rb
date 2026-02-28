# frozen_string_literal: true

require "test_helper"

module Earl
  module Mcp
    class MattermostHandlerTest < Minitest::Test
      setup do
        @api = Minitest::Mock.new
        @handler = Earl::Mcp::MattermostHandler.new(api_client: @api)
      end

      # --- tool_definitions ---

      test "tool_definitions returns one tool" do
        defs = @handler.tool_definitions
        assert_equal 1, defs.size
        assert_equal "get_thread_content", defs.first[:name]
      end

      test "tool_definitions include inputSchema with post_id" do
        schema = @handler.tool_definitions.first[:inputSchema]
        assert_equal "object", schema[:type]
        assert schema[:properties].key?(:post_id)
        assert_includes schema[:required], "post_id"
      end

      # --- handles? ---

      test "handles? returns true for get_thread_content" do
        assert @handler.handles?("get_thread_content")
      end

      test "handles? returns false for other tools" do
        assert_not @handler.handles?("save_memory")
        assert_not @handler.handles?("Bash")
      end

      # --- call with missing/empty post_id ---

      test "call returns error when post_id is missing" do
        result = @handler.call("get_thread_content", {})
        text = result[:content].first[:text]
        assert_includes text, "Error: post_id is required"
      end

      test "call returns error when post_id is empty" do
        result = @handler.call("get_thread_content", { "post_id" => "" })
        text = result[:content].first[:text]
        assert_includes text, "Error: post_id is required"
      end

      test "call returns error when post_id is whitespace only" do
        result = @handler.call("get_thread_content", { "post_id" => "   " })
        text = result[:content].first[:text]
        assert_includes text, "Error: post_id is required"
      end

      test "call coerces non-string post_id to string" do
        stub_post_response("12345", root_id: "")
        stub_thread_response("12345", build_thread_data("12345"))

        result = @handler.call("get_thread_content", { "post_id" => 12_345 })
        text = result[:content].first[:text]

        assert_includes text, "Thread transcript"
        @api.verify
      end

      test "call returns nil for unknown tool name" do
        result = @handler.call("unknown_tool", {})
        assert_nil result
      end

      # --- call with valid post_id (root post) ---

      test "call fetches thread for a root post" do
        stub_post_response("abc123", root_id: "")
        stub_thread_response("abc123", build_thread_data("abc123"))

        result = @handler.call("get_thread_content", { "post_id" => "abc123" })
        text = result[:content].first[:text]

        assert_includes text, "Thread transcript"
        assert_includes text, "Hello world"
        @api.verify
      end

      # --- call with valid post_id (reply post) ---

      test "call resolves root_id for a reply post" do
        stub_post_response("reply456", root_id: "root789")
        stub_thread_response("root789", build_thread_data("root789"))

        result = @handler.call("get_thread_content", { "post_id" => "reply456" })
        text = result[:content].first[:text]

        assert_includes text, "Thread transcript"
        @api.verify
      end

      # --- call when post fetch fails ---

      test "call returns error when post cannot be fetched" do
        stub_failed_response("/posts/bad_id")

        result = @handler.call("get_thread_content", { "post_id" => "bad_id" })
        text = result[:content].first[:text]

        assert_includes text, "Error: could not fetch post bad_id"
        @api.verify
      end

      # --- call when thread is empty ---

      test "call returns message when thread has no posts" do
        stub_post_response("empty_thread", root_id: "")
        stub_thread_response("empty_thread", { "posts" => {}, "order" => [] })

        result = @handler.call("get_thread_content", { "post_id" => "empty_thread" })
        text = result[:content].first[:text]

        assert_includes text, "No messages found"
        @api.verify
      end

      # --- transcript formatting ---

      test "call formats transcript with timestamps and senders" do
        stub_post_response("thread1", root_id: "")
        stub_thread_response("thread1", build_multi_post_thread)

        result = @handler.call("get_thread_content", { "post_id" => "thread1" })
        text = result[:content].first[:text]

        assert_includes text, "2 messages"
        assert_includes text, "User: What time is it?"
        assert_includes text, "EARL: It's 3pm"
        @api.verify
      end

      # --- JSON parse error handling ---

      test "call returns error when post response has invalid JSON" do
        response = build_success_response("not valid json")
        @api.expect(:get, response, ["/posts/bad_json"])

        result = @handler.call("get_thread_content", { "post_id" => "bad_json" })
        text = result[:content].first[:text]

        assert_includes text, "Error: could not fetch post bad_json"
        @api.verify
      end

      test "call returns no messages when thread response has invalid JSON" do
        stub_post_response("post1", root_id: "")
        response = build_success_response("not valid json")
        @api.expect(:get, response, ["/posts/post1/thread"])

        result = @handler.call("get_thread_content", { "post_id" => "post1" })
        text = result[:content].first[:text]

        assert_includes text, "No messages found"
        @api.verify
      end

      # --- HTTP error distinction ---

      test "call returns HTTP error when thread fetch fails" do
        stub_post_response("post1", root_id: "")
        stub_failed_response("/posts/post1/thread")

        result = @handler.call("get_thread_content", { "post_id" => "post1" })
        text = result[:content].first[:text]

        assert_includes text, "Error: failed to fetch thread"
        assert_includes text, "404"
        @api.verify
      end

      # --- MAX_POSTS truncation ---

      test "call truncates threads longer than MAX_POSTS" do
        stub_post_response("long_thread", root_id: "")

        posts = {}
        order = []
        60.times do |i|
          id = "p#{i}"
          posts[id] = {
            "id" => id, "create_at" => 1_700_000_000_000 + (i * 1000),
            "message" => "Message #{i}", "user_id" => "user1", "props" => {}
          }
          order.unshift(id)
        end
        stub_thread_response("long_thread", { "posts" => posts, "order" => order })

        result = @handler.call("get_thread_content", { "post_id" => "long_thread" })
        text = result[:content].first[:text]

        assert_includes text, "50 messages"
        assert_not_includes text, "Message 0"
        assert_includes text, "Message 59"
        @api.verify
      end

      private

      def stub_post_response(post_id, root_id:)
        body = JSON.generate({ "id" => post_id, "root_id" => root_id, "message" => "test" })
        response = build_success_response(body)
        @api.expect(:get, response, ["/posts/#{post_id}"])
      end

      def stub_thread_response(thread_id, data)
        body = JSON.generate(data)
        response = build_success_response(body)
        @api.expect(:get, response, ["/posts/#{thread_id}/thread"])
      end

      def stub_failed_response(path)
        response = Net::HTTPNotFound.new("1.1", "404", "Not Found")
        response.instance_variable_set(:@body, '{"message":"not found"}')
        response.instance_variable_set(:@read, true)
        @api.expect(:get, response, [path])
      end

      def build_success_response(body)
        response = Net::HTTPOK.new("1.1", "200", "OK")
        response.instance_variable_set(:@body, body)
        response.instance_variable_set(:@read, true)
        response
      end

      def build_thread_data(root_id)
        {
          "posts" => {
            root_id => {
              "id" => root_id, "create_at" => 1_700_000_000_000,
              "message" => "Hello world", "user_id" => "user1", "props" => {}
            }
          },
          "order" => [root_id]
        }
      end

      test "format_timestamp returns unknown for non-integer create_at" do
        handler = Earl::Mcp::MattermostHandler.new(api_client: @api)
        result = handler.send(:format_timestamp, "not-an-integer")
        assert_equal "unknown", result
      end

      def build_multi_post_thread
        {
          "posts" => {
            "p1" => {
              "id" => "p1", "create_at" => 1_700_000_000_000,
              "message" => "What time is it?", "user_id" => "user1", "props" => {}
            },
            "p2" => {
              "id" => "p2", "create_at" => 1_700_000_060_000,
              "message" => "It's 3pm", "user_id" => "bot1",
              "props" => { "from_bot" => "true" }
            }
          },
          "order" => %w[p2 p1]
        }
      end
    end
  end
end
