# frozen_string_literal: true

require "websocket-client-simple"

module Earl
  # Connects to the Mattermost WebSocket API for real-time messaging and
  # provides REST helpers for creating, updating posts and typing indicators.
  class Mattermost
    include Logging
    attr_reader :config

    def initialize(config)
      @config = config
      @on_message = nil
      @ws = nil
    end

    def on_message(&block)
      @on_message = block
    end

    def connect
      @ws = WebSocket::Client::Simple.connect(config.websocket_url)
      setup_websocket_handlers
    end

    def create_post(channel_id:, message:, root_id: nil)
      body = { channel_id: channel_id, message: message }
      body[:root_id] = root_id if root_id
      response = api_post("/posts", body)
      JSON.parse(response.body)
    end

    def update_post(post_id:, message:)
      body = { id: post_id, message: message }
      api_put("/posts/#{post_id}", body)
    end

    def send_typing(channel_id:, parent_id: nil)
      body = { channel_id: channel_id }
      body[:parent_id] = parent_id if parent_id
      api_post("/users/me/typing", body)
    end

    private

    def setup_websocket_handlers
      mattermost = self
      logger = Earl.logger

      @ws.on(:open) do
        logger.info "WebSocket connected, sending auth challenge"
        send(JSON.generate({
          seq: 1,
          action: "authentication_challenge",
          data: { token: mattermost.config.bot_token }
        }))
      end

      @ws.on(:message) { |msg| mattermost.send(:handle_websocket_message, msg) }
      @ws.on(:error) { |error| logger.error "WebSocket error: #{error.message}" }
      @ws.on(:close) { |event| mattermost.send(:handle_websocket_close, event) }
    end

    def handle_websocket_message(msg)
      handle_ping if msg.type == :ping
      parse_and_dispatch(msg.data)
    rescue JSON::ParserError => error
      log(:warn, "Failed to parse WebSocket message: #{error.message}")
    rescue StandardError => error
      error_msg = error.message
      log(:error, "Error handling WebSocket message: #{error.class}: #{error_msg}")
      log(:error, error.backtrace.first(5).join("\n"))
    end

    def parse_and_dispatch(data)
      return unless data && !data.empty?

      event = JSON.parse(data)
      log(:debug, "WS event: #{event['event'] || event.keys.first}")
      dispatch_event(event)
    end

    def handle_ping
      log(:debug, "WS ping received, sending pong")
      @ws.send(nil, type: :pong)
    end

    def dispatch_event(event)
      case event["event"]
      when "hello"
        log(:info, "Authenticated to Mattermost")
      when "posted"
        handle_posted_event(event)
      end
    end

    def handle_posted_event(event)
      post_data = event.dig("data", "post")
      return unless post_data

      post = JSON.parse(post_data)
      return if post["user_id"] == config.bot_id
      return if post["channel_id"] != config.channel_id

      deliver_message(event, post)
    end

    def deliver_message(event, post)
      sender_name = event.dig("data", "sender_name")&.delete_prefix("@") || "unknown"
      post_id = post["id"]
      root_id = post["root_id"]
      thread_id = root_id.to_s.empty? ? post_id : root_id
      message_text = post["message"] || ""

      log(:info, "Message from @#{sender_name} in thread #{thread_id[0..7]}: #{message_text[0..80]}")
      @on_message&.call(sender_name: sender_name, thread_id: thread_id, text: message_text, post_id: post_id)
    end

    def handle_websocket_close(event)
      log(:warn, "WebSocket closed: #{event&.code} #{event&.reason}")
      log(:warn, "EARL will exit — restart process to reconnect")
      exit 1
    end

    def api_request(method_class, path, body)
      uri = URI.parse(config.api_url(path))
      req = build_request(method_class, uri, body)
      response = execute_request(uri, req)

      unless response.is_a?(Net::HTTPSuccess)
        log(:error, "Mattermost API #{req.method} #{path} failed: #{response.code} #{response.body[0..200]}")
      end

      response
    end

    def build_request(method_class, uri, body)
      req = method_class.new(uri)
      req["Authorization"] = "Bearer #{config.bot_token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
      req
    end

    def execute_request(uri, req)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 15
      http.request(req)
    end

    def api_post(path, body)
      api_request(Net::HTTP::Post, path, body)
    end

    def api_put(path, body)
      api_request(Net::HTTP::Put, path, body)
    end
  end
end
