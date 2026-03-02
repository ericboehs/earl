# frozen_string_literal: true

require "test_helper"

module Earl
  module Cli
    class ThreadTest < Minitest::Test
      setup do
        @api = Minitest::Mock.new
        @handler = Earl::Cli::Thread.new(api_client: @api)
      end

      # --- valid root post ---

      test "run prints transcript for a root post" do
        stub_post_response("abc123", root_id: "")
        stub_thread_response("abc123", build_thread_data("abc123"))

        output = capture_io { @handler.run(["abc123"]) }.first
        assert_includes output, "Thread transcript"
        assert_includes output, "Hello world"
        @api.verify
      end

      # --- valid reply post ---

      test "run resolves root_id for a reply post" do
        stub_post_response("reply456", root_id: "root789")
        stub_thread_response("root789", build_thread_data("root789"))

        output = capture_io { @handler.run(["reply456"]) }.first
        assert_includes output, "Thread transcript"
        @api.verify
      end

      # --- missing post_id ---

      test "run aborts when post_id is missing" do
        error = assert_raises(SystemExit) { capture_io { @handler.run([]) } }
        assert_equal 1, error.status
      end

      test "run aborts when post_id is empty" do
        error = assert_raises(SystemExit) { capture_io { @handler.run([""]) } }
        assert_equal 1, error.status
      end

      # --- post fetch failure ---

      test "run aborts when post cannot be fetched" do
        stub_failed_response("/posts/bad_id")

        error = assert_raises(SystemExit) { capture_io { @handler.run(["bad_id"]) } }
        assert_equal 1, error.status
        @api.verify
      end

      # --- empty thread ---

      test "run aborts when thread has no posts" do
        stub_post_response("empty", root_id: "")
        stub_thread_response("empty", { "posts" => {}, "order" => [] })

        error = assert_raises(SystemExit) { capture_io { @handler.run(["empty"]) } }
        assert_equal 1, error.status
        @api.verify
      end

      # --- thread fetch HTTP failure ---

      test "run aborts with HTTP status when thread fetch fails" do
        stub_post_response("post1", root_id: "")
        stub_failed_response("/posts/post1/thread")

        _stdout, stderr = capture_io do
          assert_raises(SystemExit) { @handler.run(["post1"]) }
        end
        assert_includes stderr, "HTTP 404"
        @api.verify
      end

      # --- JSON parse errors ---

      test "run warns and aborts when post response has invalid JSON" do
        response = build_success_response("not valid json")
        @api.expect(:get, response, ["/posts/bad_json"])

        _stdout, stderr = capture_io do
          assert_raises(SystemExit) { @handler.run(["bad_json"]) }
        end
        assert_includes stderr, "failed to parse response"
        @api.verify
      end

      test "run warns when thread response has invalid JSON" do
        stub_post_response("post1", root_id: "")
        response = build_success_response("not valid json")
        @api.expect(:get, response, ["/posts/post1/thread"])

        _stdout, stderr = capture_io do
          assert_raises(SystemExit) { @handler.run(["post1"]) }
        end
        assert_includes stderr, "failed to parse thread response"
        @api.verify
      end

      # --- multi-post thread formatting ---

      test "run formats multiple posts with senders" do
        stub_post_response("thread1", root_id: "")
        stub_thread_response("thread1", build_multi_post_thread)

        output = capture_io { @handler.run(["thread1"]) }.first
        assert_includes output, "2 messages"
        assert_includes output, "User: What time is it?"
        assert_includes output, "EARL: It's 3pm"
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
