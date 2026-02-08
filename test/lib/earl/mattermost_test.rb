require "test_helper"

# :reek:TooManyMethods
class Earl::MattermostTest < ActiveSupport::TestCase
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

  # --- Private HTTP method tests ---

  test "api_post builds correct HTTP request with auth and SSL" do
    mm = Earl::Mattermost.new(@config)
    captured_req = nil
    ssl_set = nil

    with_http_mock(
      on_request: ->(req) { captured_req = req },
      on_ssl: ->(v) { ssl_set = v },
      response_body: '{"ok":true}'
    ) do
      mm.send(:api_post, "/test/path", { key: "value" })
    end

    assert_instance_of Net::HTTP::Post, captured_req
    assert_equal "Bearer test-token", captured_req["Authorization"]
    assert_equal "application/json", captured_req["Content-Type"]
    assert_equal true, ssl_set

    body = JSON.parse(captured_req.body)
    assert_equal "value", body["key"]
  end

  test "api_put builds correct HTTP request" do
    mm = Earl::Mattermost.new(@config)
    captured_req = nil

    with_http_mock(on_request: ->(req) { captured_req = req }) do
      mm.send(:api_put, "/test/path", { id: "123" })
    end

    assert_instance_of Net::HTTP::Put, captured_req
    assert_equal "Bearer test-token", captured_req["Authorization"]

    body = JSON.parse(captured_req.body)
    assert_equal "123", body["id"]
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

  private

  def build_testable_mattermost
    requests = @requests
    mm = Earl::Mattermost.new(@config)

    mm.define_singleton_method(:api_post) do |path, body|
      requests << { method: :post, path: path, body: body, auth: "Bearer #{config.bot_token}" }
      response = Object.new
      response.define_singleton_method(:body) { JSON.generate({ "id" => "fake-post-id" }) }
      response
    end

    mm.define_singleton_method(:api_put) do |path, body|
      requests << { method: :put, path: path, body: body, auth: "Bearer #{config.bot_token}" }
      Object.new
    end

    mm
  end

  def with_http_mock(on_request: nil, on_ssl: nil, response_body: "{}")
    original = Net::HTTP.method(:new)
    mock = Object.new
    mock.define_singleton_method(:use_ssl=) { |v| on_ssl&.call(v) }
    mock.define_singleton_method(:open_timeout=) { |_v| }
    mock.define_singleton_method(:read_timeout=) { |_v| }
    mock.define_singleton_method(:request) do |req|
      on_request&.call(req)
      resp = Object.new
      rb = response_body
      resp.define_singleton_method(:body) { rb }
      resp.define_singleton_method(:code) { "200" }
      resp.define_singleton_method(:is_a?) do |klass|
        klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
      end
      resp
    end

    Net::HTTP.define_singleton_method(:new) { |*_args| mock }
    yield
  ensure
    Net::HTTP.define_singleton_method(:new, original)
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

    def fire(event, *args)
      block = @handlers[event]
      return unless block

      instance_exec(*args, &block)
    end
  end
end
