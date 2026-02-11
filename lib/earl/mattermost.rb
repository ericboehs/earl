# frozen_string_literal: true

require "websocket-client-simple"
require_relative "mattermost/api_client"

module Earl
  # Connects to the Mattermost WebSocket API for real-time messaging and
  # provides REST helpers for creating, updating posts and typing indicators.
  class Mattermost
    include Logging
    attr_reader :config

    def initialize(config)
      @config = config
      @api = ApiClient.new(config)
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
      parse_post_response(@api.post("/posts", body))
    end

    def update_post(post_id:, message:)
      @api.put("/posts/#{post_id}", { id: post_id, message: message })
    end

    def send_typing(channel_id:, parent_id: nil)
      body = { channel_id: channel_id }
      body[:parent_id] = parent_id if parent_id
      @api.post("/users/me/typing", body)
    end

    private

    # WebSocket lifecycle methods extracted to reduce class method count.
    module WebSocketHandling
      private

      def setup_websocket_handlers
        ws_ref = self
        websocket_handler_map(ws_ref).each { |event, handler| @ws.on(event, &handler) }
      end

      # :reek:FeatureEnvy
      def websocket_handler_map(ws_ref)
        {
          open: -> { send(JSON.generate(ws_ref.send(:auth_payload))) },
          message: ->(msg) { ws_ref.send(:handle_websocket_message, msg) },
          error: ->(error) { Earl.logger.error "WebSocket error: #{error.message}" },
          close: ->(event) { ws_ref.send(:handle_websocket_close, event) }
        }
      end

      def auth_payload
        Earl.logger.info "WebSocket connected, sending auth challenge"
        { seq: 1, action: "authentication_challenge", data: { token: config.bot_token } }
      end

      def handle_websocket_message(msg)
        handle_ping if msg.type == :ping
        parse_and_dispatch(msg.data)
      rescue StandardError => error
        log(:error, "WebSocket message error: #{error.class}: #{error.message}")
        log(:error, error.backtrace&.first(5)&.join("\n"))
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

      def handle_websocket_close(event)
        log(:warn, "WebSocket closed: #{event&.code} #{event&.reason}")
        log(:warn, "EARL will exit — restart process to reconnect")
        exit 1
      end
    end

    include WebSocketHandling

    def handle_posted_event(event)
      post = parse_post_data(event)
      deliver_message(event, post) if post
    end

    def parse_post_data(event)
      post_data = event.dig("data", "post")
      return unless post_data

      post = JSON.parse(post_data)
      return if post["user_id"] == config.bot_id || post["channel_id"] != config.channel_id

      post
    end

    def deliver_message(event, post)
      params = build_message_params(event, post)
      log(:info, "Message from @#{params[:sender_name]} in thread #{params[:thread_id][0..7]}: #{params[:text][0..80]}")
      @on_message&.call(**params)
    end

    def build_message_params(event, post)
      post_id = post["id"]
      root_id = post["root_id"]
      sender = event.dig("data", "sender_name")&.delete_prefix("@") || "unknown"
      { sender_name: sender, thread_id: root_id.to_s.empty? ? post_id : root_id, text: post["message"] || "", post_id: post_id }
    end

    def parse_post_response(response)
      return {} unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end
end
