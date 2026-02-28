# frozen_string_literal: true

require "test_helper"

# Tests Mattermost REST API, WebSocket connection, and event dispatch
module Earl
  class MattermostTest < Minitest::Test
    setup do
      Earl.logger = Logger.new(File::NULL)

      @original_env = ENV.to_h.slice(
        "MATTERMOST_URL", "MATTERMOST_BOT_TOKEN", "MATTERMOST_BOT_ID",
        "EARL_CHANNEL_ID", "EARL_ALLOWED_USERS"
      )

      ENV["MATTERMOST_URL"] = "https://mattermost.example.com"
      ENV["MATTERMOST_BOT_TOKEN"] = "test-token"
      ENV["MATTERMOST_BOT_ID"] = "bot-123"
      ENV["EARL_CHANNEL_ID"] = "channel-456"
      ENV["EARL_ALLOWED_USERS"] = ""

      @config = Earl::Config.new
      @requests = []
      @mattermost = build_testable_mattermost
      @original_ws_connect = WebSocket::Client::Simple.method(:connect)
    end

    teardown do
      Earl.logger = nil
      WebSocket::Client::Simple.define_singleton_method(:connect, @original_ws_connect)
      %w[MATTERMOST_URL MATTERMOST_BOT_TOKEN MATTERMOST_BOT_ID EARL_CHANNEL_ID EARL_ALLOWED_USERS].each do |key|
        if @original_env.key?(key)
          ENV[key] = @original_env[key]
        else
          ENV.delete(key)
        end
      end
    end

    # --- REST API tests (using overridden api_post/api_put) ---

    test "create_post sends POST with correct body and returns parsed response" do
      result = @mattermost.create_post(channel_id: "ch-1", message: "Hello", root_id: "root-1")

      assert_equal "fake-post-id", result["id"]

      req = @requests.last
      assert_equal :post, req[:method]
      assert_equal "/posts", req[:path]
      assert_equal "ch-1", req[:body][:channel_id]
      assert_equal "Hello", req[:body][:message]
      assert_equal "root-1", req[:body][:root_id]
      assert_equal "Bearer test-token", req[:auth]
    end

    test "create_post omits root_id when nil" do
      @mattermost.create_post(channel_id: "ch-1", message: "Hi")

      body = @requests.last[:body]
      assert_not body.key?(:root_id)
    end

    test "update_post sends PUT request" do
      @mattermost.update_post(post_id: "post-1", message: "Updated text")

      req = @requests.last
      assert_equal :put, req[:method]
      assert_equal "/posts/post-1", req[:path]
      assert_equal "post-1", req[:body][:id]
      assert_equal "Updated text", req[:body][:message]
    end

    test "send_typing sends POST to typing endpoint" do
      @mattermost.send_typing(channel_id: "ch-1", parent_id: "parent-1")

      req = @requests.last
      assert_equal :post, req[:method]
      assert_equal "/users/me/typing", req[:path]
      assert_equal "ch-1", req[:body][:channel_id]
      assert_equal "parent-1", req[:body][:parent_id]
    end

    test "send_typing omits parent_id when nil" do
      @mattermost.send_typing(channel_id: "ch-1")

      body = @requests.last[:body]
      assert_not body.key?(:parent_id)
    end

    test "on_message stores callback" do
      mm = Earl::Mattermost.new(@config)
      called = false
      mm.on_message { called = true }
      assert_not called
    end

    test "create_post returns empty hash on non-success response" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      api.define_singleton_method(:post) do |_path, _body|
        response = Object.new
        response.define_singleton_method(:body) { '{"error":"unauthorized"}' }
        response.define_singleton_method(:code) { "401" }
        response.define_singleton_method(:is_a?) do |klass|
          Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      result = mm.create_post(channel_id: "ch-1", message: "Hello")
      assert_equal({}, result)
    end

    test "parse_post_response returns empty hash on JSON parse error" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      api.define_singleton_method(:post) do |_path, _body|
        response = Object.new
        response.define_singleton_method(:body) { "not json{{{" }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      result = mm.create_post(channel_id: "ch-1", message: "Hello")
      assert_equal({}, result)
    end

    # --- Private HTTP method tests (via ApiClient) ---

    test "api_client post builds correct HTTP request with auth and SSL" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)
      captured_req = nil
      ssl_set = nil

      with_http_mock(
        on_request: ->(req) { captured_req = req },
        on_ssl: ->(v) { ssl_set = v },
        response_body: '{"ok":true}'
      ) do
        api.post("/test/path", { key: "value" })
      end

      assert_instance_of Net::HTTP::Post, captured_req
      assert_equal "Bearer test-token", captured_req["Authorization"]
      assert_equal "application/json", captured_req["Content-Type"]
      assert_equal true, ssl_set

      body = JSON.parse(captured_req.body)
      assert_equal "value", body["key"]
    end

    test "api_client put builds correct HTTP request" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)
      captured_req = nil

      with_http_mock(on_request: ->(req) { captured_req = req }) do
        api.put("/test/path", { id: "123" })
      end

      assert_instance_of Net::HTTP::Put, captured_req
      assert_equal "Bearer test-token", captured_req["Authorization"]

      body = JSON.parse(captured_req.body)
      assert_equal "123", body["id"]
    end

    test "api_client execute logs error on non-success response" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)
      logged_errors = []

      Earl.logger.define_singleton_method(:error) do |msg|
        logged_errors << msg
      end

      with_http_mock(response_body: '{"error":"forbidden"}', success: false) do
        api.post("/failing/path", { key: "value" })
      end

      error_log = logged_errors.find { |m| m.include?("failing/path") }
      assert_not_nil error_log, "Expected an error log for failed API call"
      assert_includes error_log, "401"
    end

    test "api_client execute returns response even on failure" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      with_http_mock(response_body: '{"error":"forbidden"}', success: false) do
        response = api.post("/failing/path", { key: "value" })
        assert_not_nil response
        assert_equal "401", response.code
      end
    end

    test "api_client delete builds correct HTTP request without body" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)
      captured_req = nil

      with_http_mock(
        on_request: ->(req) { captured_req = req },
        response_body: '{"status":"OK"}'
      ) do
        api.delete("/posts/post-1")
      end

      assert_instance_of Net::HTTP::Delete, captured_req
      assert_equal "Bearer test-token", captured_req["Authorization"]
      assert_nil captured_req.body
    end

    # --- WebSocket connect tests ---

    test "connect sets up WebSocket with auth challenge" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.connect

      fake_ws.fire(:open)

      assert_equal 1, fake_ws.sent_messages.size
      auth = JSON.parse(fake_ws.sent_messages.first[:data])
      assert_equal "authentication_challenge", auth["action"]
      assert_equal "test-token", auth.dig("data", "token")
    end

    test "connect handles hello event" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.connect

      msg = ws_message(type: :text, data: JSON.generate({ "event" => "hello" }))
      assert_nothing_raised { fake_ws.fire(:message, msg) }
    end

    test "connect handles posted event and calls on_message callback" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      post_data = {
        "id" => "post-abc", "user_id" => "user-999",
        "channel_id" => "channel-456", "root_id" => "", "message" => "Hello Earl"
      }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data), "sender_name" => "@alice" } }

      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_not_nil received
      assert_equal "alice", received[:sender_name]
      assert_equal "post-abc", received[:thread_id]
      assert_equal "Hello Earl", received[:text]
    end

    test "connect uses root_id as thread_id for replies" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      post_data = {
        "id" => "reply-post", "user_id" => "user-999",
        "channel_id" => "channel-456", "root_id" => "original-thread", "message" => "follow-up"
      }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data), "sender_name" => "@bob" } }

      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_equal "original-thread", received[:thread_id]
    end

    test "connect ignores bot's own messages" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      post_data = { "user_id" => "bot-123", "channel_id" => "channel-456", "message" => "Hi" }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data) } }

      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))
      assert_nil received
    end

    test "connect ignores messages from other channels" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      post_data = { "user_id" => "user-999", "channel_id" => "other-channel", "message" => "Hi" }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data) } }

      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))
      assert_nil received
    end

    test "connect responds to ping with pong" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.connect

      fake_ws.fire(:message, ws_message(type: :ping, data: nil))

      pongs = fake_ws.sent_messages.select { |m| m[:opts][:type] == :pong }
      assert pongs.any?, "Expected a pong response"
    end

    test "connect handles JSON parse errors gracefully" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.connect

      assert_nothing_raised do
        fake_ws.fire(:message, ws_message(type: :text, data: "not valid json{{{"))
      end
    end

    test "connect handles empty and nil data" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.connect

      assert_nothing_raised do
        fake_ws.fire(:message, ws_message(type: :text, data: ""))
        fake_ws.fire(:message, ws_message(type: :text, data: nil))
      end
    end

    test "connect handles error events" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.connect

      error = Object.new
      error.define_singleton_method(:message) { "test error" }
      assert_nothing_raised { fake_ws.fire(:error, error) }
    end

    test "connect exits on close event" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.connect

      close_event = Object.new
      close_event.define_singleton_method(:code) { 1000 }
      close_event.define_singleton_method(:reason) { "normal" }
      assert_raises(SystemExit) { fake_ws.fire(:close, close_event) }
    end

    test "connect ignores non-hello non-posted events" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      event = { "event" => "typing", "data" => {} }
      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_nil received
    end

    test "connect handles posted event with nil post data" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      event = { "event" => "posted", "data" => {} }
      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_nil received
    end

    test "connect uses unknown for missing sender_name" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      post_data = {
        "id" => "post-1", "user_id" => "user-999",
        "channel_id" => "channel-456", "root_id" => "", "message" => "Hi"
      }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data) } }
      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_equal "unknown", received[:sender_name]
    end

    test "connect handles posted event without on_message callback" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      # Don't set on_message callback
      mm.connect

      post_data = {
        "id" => "post-1", "user_id" => "user-999",
        "channel_id" => "channel-456", "root_id" => "", "message" => "Hi"
      }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data), "sender_name" => "@alice" } }

      assert_nothing_raised { fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event))) }
    end

    test "connect handles generic errors in message handler" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.on_message { |**_kwargs| raise "something broke" }
      mm.connect

      post_data = {
        "id" => "post-1", "user_id" => "user-999",
        "channel_id" => "channel-456", "root_id" => "", "message" => "Hi"
      }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data), "sender_name" => "@alice" } }

      assert_nothing_raised { fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event))) }
    end

    test "connect exits on close event with nil" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.connect

      assert_raises(SystemExit) { fake_ws.fire(:close, nil) }
    end

    # --- add_reaction tests ---

    test "add_reaction sends POST to reactions endpoint" do
      @mattermost.add_reaction(post_id: "post-1", emoji_name: "+1")

      req = @requests.last
      assert_equal :post, req[:method]
      assert_equal "/reactions", req[:path]
      assert_equal "bot-123", req[:body][:user_id]
      assert_equal "post-1", req[:body][:post_id]
      assert_equal "+1", req[:body][:emoji_name]
    end

    # --- delete_post tests ---

    test "delete_post sends DELETE request" do
      @mattermost.delete_post(post_id: "post-1")

      req = @requests.last
      assert_equal :delete, req[:method]
      assert_equal "/posts/post-1", req[:path]
    end

    # --- get_thread_posts tests ---

    test "get_thread_posts returns posts ordered oldest-first" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      thread_data = {
        "posts" => {
          "post-1" => { "id" => "post-1", "user_id" => "user-999", "message" => "!sessions", "props" => {} },
          "post-2" => { "id" => "post-2", "user_id" => "bot-123", "message" => "Session list...",
                        "props" => { "from_bot" => "true" } },
          "post-3" => { "id" => "post-3", "user_id" => "user-999", "message" => "Can u approve 4", "props" => {} }
        },
        "order" => %w[post-3 post-2 post-1]
      }

      api.define_singleton_method(:get) do |_path|
        response = Object.new
        response.define_singleton_method(:body) { JSON.generate(thread_data) }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      posts = mm.get_thread_posts("post-1")
      assert_equal 3, posts.size
      assert_equal "!sessions", posts[0][:message]
      assert_equal "user", posts[0][:sender]
      assert_equal "Session list...", posts[1][:message]
      assert_equal "EARL", posts[1][:sender]
      assert posts[1][:is_bot]
      assert_equal "Can u approve 4", posts[2][:message]
    end

    test "get_thread_posts includes file_ids from posts" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      thread_data = {
        "posts" => {
          "post-1" => { "id" => "post-1", "user_id" => "user-999", "message" => "see this",
                        "props" => {}, "file_ids" => %w[file-a file-b] },
          "post-2" => { "id" => "post-2", "user_id" => "bot-123", "message" => "I see it",
                        "props" => { "from_bot" => "true" } }
        },
        "order" => %w[post-2 post-1]
      }

      api.define_singleton_method(:get) do |_path|
        response = Object.new
        response.define_singleton_method(:body) { JSON.generate(thread_data) }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      posts = mm.get_thread_posts("post-1")
      assert_equal %w[file-a file-b], posts[0][:file_ids]
      assert_equal [], posts[1][:file_ids]
    end

    test "get_thread_posts returns empty array on API failure" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      api.define_singleton_method(:get) do |_path|
        response = Object.new
        response.define_singleton_method(:body) { '{"error":"not found"}' }
        response.define_singleton_method(:code) { "404" }
        response.define_singleton_method(:is_a?) do |klass|
          Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      assert_equal [], mm.get_thread_posts("nonexistent")
    end

    test "get_thread_posts returns empty array on JSON parse error" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      api.define_singleton_method(:get) do |_path|
        response = Object.new
        response.define_singleton_method(:body) { "not json{{{" }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      assert_equal [], mm.get_thread_posts("post-1")
    end

    # --- get_user tests ---

    test "get_user sends GET and returns parsed user" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      api.define_singleton_method(:get) do |_path|
        response = Object.new
        response.define_singleton_method(:body) { JSON.generate({ "id" => "user-1", "username" => "alice" }) }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      user = mm.get_user(user_id: "user-1")
      assert_equal "alice", user["username"]
    end

    test "get_user returns empty hash on failure" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      api.define_singleton_method(:get) do |_path|
        response = Object.new
        response.define_singleton_method(:body) { '{"error":"not found"}' }
        response.define_singleton_method(:code) { "404" }
        response.define_singleton_method(:is_a?) do |klass|
          Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      assert_equal({}, mm.get_user(user_id: "user-unknown"))
    end

    # --- on_reaction callback tests ---

    test "on_reaction stores callback" do
      mm = Earl::Mattermost.new(@config)
      called = false
      mm.on_reaction { called = true }
      assert_not called
    end

    test "reaction_added event fires on_reaction callback" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_reaction { |**kwargs| received = kwargs }
      mm.connect

      reaction_data = { "user_id" => "user-999", "post_id" => "post-abc", "emoji_name" => "+1" }
      event = { "event" => "reaction_added", "data" => { "reaction" => JSON.generate(reaction_data) } }

      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_not_nil received
      assert_equal "user-999", received[:user_id]
      assert_equal "post-abc", received[:post_id]
      assert_equal "+1", received[:emoji_name]
    end

    test "reaction_added ignores bot's own reactions" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_reaction { |**kwargs| received = kwargs }
      mm.connect

      reaction_data = { "user_id" => "bot-123", "post_id" => "post-abc", "emoji_name" => "+1" }
      event = { "event" => "reaction_added", "data" => { "reaction" => JSON.generate(reaction_data) } }

      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_nil received
    end

    test "reaction_added handles nil reaction data" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_reaction { |**kwargs| received = kwargs }
      mm.connect

      event = { "event" => "reaction_added", "data" => {} }

      assert_nothing_raised { fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event))) }
      assert_nil received
    end

    test "reaction_added handles invalid JSON reaction data" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_reaction { |**kwargs| received = kwargs }
      mm.connect

      event = { "event" => "reaction_added", "data" => { "reaction" => "not json{{" } }

      assert_nothing_raised { fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event))) }
      assert_nil received
    end

    # --- channel_id in message params ---

    test "connect includes channel_id in message params" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      post_data = {
        "id" => "post-abc", "user_id" => "user-999",
        "channel_id" => "channel-456", "root_id" => "", "message" => "Hello Earl"
      }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data), "sender_name" => "@alice" } }

      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_not_nil received
      assert_equal "channel-456", received[:channel_id]
    end

    # --- file_ids in message params ---

    test "connect includes file_ids in message params when present" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      post_data = {
        "id" => "post-abc", "user_id" => "user-999",
        "channel_id" => "channel-456", "root_id" => "", "message" => "See image",
        "file_ids" => %w[file-1 file-2]
      }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data), "sender_name" => "@alice" } }

      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_not_nil received
      assert_equal %w[file-1 file-2], received[:file_ids]
    end

    test "connect returns empty file_ids when post has no file_ids" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      received = nil
      mm.on_message { |**kwargs| received = kwargs }
      mm.connect

      post_data = {
        "id" => "post-abc", "user_id" => "user-999",
        "channel_id" => "channel-456", "root_id" => "", "message" => "No files"
      }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post_data), "sender_name" => "@alice" } }

      fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event)))

      assert_not_nil received
      assert_equal [], received[:file_ids]
    end

    # --- file download and info tests ---

    test "download_file sends GET to files endpoint" do
      @mattermost.download_file("file-123")

      req = @requests.last
      assert_equal :get, req[:method]
      assert_equal "/files/file-123", req[:path]
    end

    test "get_file_info sends GET to file info endpoint" do
      @mattermost.get_file_info("file-123")

      req = @requests.last
      assert_equal :get, req[:method]
      assert_equal "/files/file-123/info", req[:path]
    end

    # --- API client GET test ---

    test "api_client get builds correct HTTP request without body" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)
      captured_req = nil

      with_http_mock(
        on_request: ->(req) { captured_req = req },
        response_body: '{"id":"user-1","username":"alice"}'
      ) do
        api.get("/users/user-1")
      end

      assert_instance_of Net::HTTP::Get, captured_req
      assert_equal "Bearer test-token", captured_req["Authorization"]
      assert_nil captured_req.body
    end

    test "get_thread_posts skips order IDs not present in posts hash" do
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      thread_data = {
        "posts" => {
          "post-1" => { "id" => "post-1", "user_id" => "user-999", "message" => "Hello", "props" => {} }
        },
        "order" => %w[post-3 post-2 post-1]
      }

      api.define_singleton_method(:get) do |_path|
        response = Object.new
        response.define_singleton_method(:body) { JSON.generate(thread_data) }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      posts = mm.get_thread_posts("post-1")
      assert_equal 1, posts.size
      assert_equal "Hello", posts[0][:message]
    end

    test "dispatch_reaction with no on_reaction callback does not raise" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      # Do NOT set on_reaction — callback is nil
      mm.connect

      reaction_data = { "user_id" => "user-999", "post_id" => "post-abc", "emoji_name" => "+1" }
      event = { "event" => "reaction_added", "data" => { "reaction" => JSON.generate(reaction_data) } }

      assert_nothing_raised { fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event))) }
    end

    test "handle_websocket_message rescues error with non-nil backtrace" do
      fake_ws = build_fake_ws
      install_fake_ws(fake_ws)

      mm = Earl::Mattermost.new(@config)
      mm.on_message { |**_kwargs| raise "kaboom" }
      mm.connect

      post = { "user_id" => "user-999", "channel_id" => "channel-456", "message" => "hi" }
      event = { "event" => "posted", "data" => { "post" => JSON.generate(post) } }

      assert_nothing_raised { fake_ws.fire(:message, ws_message(type: :text, data: JSON.generate(event))) }
    end

    private

    def build_testable_mattermost
      requests = @requests
      mm = Earl::Mattermost.new(@config)
      api = mm.instance_variable_get(:@api)

      api.define_singleton_method(:get) do |path|
        requests << { method: :get, path: path, body: nil, auth: "Bearer test-token" }
        response = Object.new
        response.define_singleton_method(:body) { JSON.generate({ "id" => "fake-id" }) }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      api.define_singleton_method(:post) do |path, body|
        requests << { method: :post, path: path, body: body, auth: "Bearer test-token" }
        response = Object.new
        response.define_singleton_method(:body) { JSON.generate({ "id" => "fake-post-id" }) }
        response.define_singleton_method(:is_a?) do |klass|
          klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        response
      end

      api.define_singleton_method(:put) do |path, body|
        requests << { method: :put, path: path, body: body, auth: "Bearer test-token" }
        Object.new
      end

      api.define_singleton_method(:delete) do |path|
        requests << { method: :delete, path: path, body: nil, auth: "Bearer test-token" }
        Object.new
      end

      mm
    end

    def with_http_mock(on_request: nil, on_ssl: nil, response_body: "{}", success: true)
      original_start = Net::HTTP.method(:start)
      is_success = success
      mock_response = proc do |req|
        on_request&.call(req)
        resp = Object.new
        rb = response_body
        resp.define_singleton_method(:body) { rb }
        resp.define_singleton_method(:code) { is_success ? "200" : "401" }
        resp.define_singleton_method(:is_a?) do |klass|
          (is_success && klass == Net::HTTPSuccess) || Object.instance_method(:is_a?).bind_call(self, klass)
        end
        resp
      end

      Net::HTTP.define_singleton_method(:start) do |_host, _port, **kwargs, &block|
        on_ssl&.call(kwargs[:use_ssl])
        mock_http = Object.new
        mock_http.define_singleton_method(:request) { |req| mock_response.call(req) }
        block ? block.call(mock_http) : mock_http
      end
      yield
    ensure
      Net::HTTP.define_singleton_method(:start, original_start)
    end

    # Fake WebSocket that executes handlers with instance_exec like the real gem
    def build_fake_ws
      FakeWebSocket.new
    end

    def install_fake_ws(fake_ws)
      WebSocket::Client::Simple.define_singleton_method(:connect) { |_url| fake_ws }
    end

    def ws_message(type:, data:)
      msg = Object.new
      msg.define_singleton_method(:type) { type }
      msg.define_singleton_method(:data) { data }
      msg
    end

    # Fake WebSocket that mimics websocket-client-simple's instance_exec behavior
    class FakeWebSocket
      attr_reader :sent_messages

      def initialize
        @handlers = {}
        @sent_messages = []
      end

      def on(event, &block)
        @handlers[event] = block
      end

      # Override send to capture messages (like WS client's send)
      def send(data = nil, **opts)
        @sent_messages << { data: data, opts: opts }
      end

      def fire(event, *)
        block = @handlers[event]
        return unless block

        instance_exec(*, &block)
      end
    end
  end
end
