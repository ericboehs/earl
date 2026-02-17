# frozen_string_literal: true

require "websocket-client-simple"
require_relative "mattermost/api_client"

module Earl
  # Connects to the Mattermost WebSocket API for real-time messaging and
  # provides REST helpers for creating, updating posts and typing indicators.
  class Mattermost
    include Logging
    attr_reader :config

    # Groups WebSocket connection state.
    Connection = Struct.new(:ws, :channel_ids, keyword_init: true)

    # Groups event callbacks.
    Callbacks = Struct.new(:on_message, :on_reaction, keyword_init: true)

    def initialize(config)
      @config = config
      @api = ApiClient.new(config)
      @connection = Connection.new(ws: nil, channel_ids: Set.new([ config.channel_id ]))
      @callbacks = Callbacks.new
    end

    def configure_channels(channel_ids)
      @connection.channel_ids = channel_ids
    end

    def on_message(&block)
      @callbacks.on_message = block
    end

    def on_reaction(&block)
      @callbacks.on_reaction = block
    end

    def connect
      @connection.ws = WebSocket::Client::Simple.connect(config.websocket_url)
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

    def add_reaction(post_id:, emoji_name:)
      @api.post("/reactions", { user_id: config.bot_id, post_id: post_id, emoji_name: emoji_name })
    end

    def delete_post(post_id:)
      @api.delete("/posts/#{post_id}")
    end

    def get_user(user_id:)
      parse_post_response(@api.get("/users/#{user_id}"))
    end

    # Fetches all posts in a thread, ordered oldest-first.
    # Returns an array of hashes with :sender, :message, :is_bot.
    def get_thread_posts(thread_id)
      response = @api.get("/posts/#{thread_id}/thread")
      return [] unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      posts = data["posts"] || {}
      order = data["order"] || []

      order.reverse.filter_map do |post_id|
        post = posts[post_id]
        next unless post

        {
          sender: post.dig("props", "from_bot") == "true" ? "EARL" : "user",
          message: post["message"] || "",
          is_bot: post["user_id"] == config.bot_id
        }
      end
    rescue JSON::ParserError => error
      log(:warn, "Failed to parse thread posts: #{error.message}")
      []
    end

    private

    # WebSocket lifecycle methods extracted to reduce class method count.
    module WebSocketHandling
      private

      def setup_websocket_handlers
        ws_ref = self
        websocket_handler_map(ws_ref).each { |event, handler| @connection.ws.on(event, &handler) }
      end

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

        event = parse_ws_json(data)
        return unless event

        log(:debug, "WS event: #{event['event'] || event.keys.first}")
        dispatch_event(event)
      end

      def parse_ws_json(data)
        JSON.parse(data)
      rescue JSON::ParserError => error
        log(:warn, "Failed to parse WebSocket message: #{error.message}")
        nil
      end

      def handle_ping
        log(:debug, "WS ping received, sending pong")
        @connection.ws.send(nil, type: :pong)
      end

      def dispatch_event(event)
        case event["event"]
        when "hello"
          log(:info, "Authenticated to Mattermost")
        when "posted"
          handle_posted_event(event)
        when "reaction_added"
          handle_reaction_event(event)
        end
      end

      def handle_websocket_close(event)
        log(:warn, "WebSocket closed: #{event&.code} #{event&.reason}")
        log(:warn, "EARL will exit — restart process to reconnect")
        exit 1
      end
    end

    # Event dispatching: routes posted and reaction events to callbacks.
    module EventDispatching
      private

      def handle_posted_event(event)
        post = parse_post_data(event)
        deliver_message(event, post) if post
      end

      def handle_reaction_event(event)
        reaction_data = event.dig("data", "reaction")
        return unless reaction_data

        reaction = JSON.parse(reaction_data)
        user_id = reaction["user_id"]
        return if user_id == config.bot_id

        @callbacks.on_reaction&.call(
          user_id: user_id,
          post_id: reaction["post_id"],
          emoji_name: reaction["emoji_name"]
        )
      rescue JSON::ParserError => error
        log(:warn, "Failed to parse reaction data: #{error.message}")
      end

      def parse_post_data(event)
        post_data = event.dig("data", "post")
        return unless post_data

        post = JSON.parse(post_data)
        return if post["user_id"] == config.bot_id || !@connection.channel_ids.include?(post["channel_id"])

        post
      end

      def deliver_message(event, post)
        params = build_message_params(event, post)
        log(:info, "Message from @#{params[:sender_name]} in thread #{params[:thread_id][0..7]}: #{params[:text][0..80]}")
        @callbacks.on_message&.call(**params)
      end

      def build_message_params(event, post)
        post_id = post["id"]
        root_id = post["root_id"]
        sender = event.dig("data", "sender_name")&.delete_prefix("@") || "unknown"
        {
          sender_name: sender,
          thread_id: root_id.to_s.empty? ? post_id : root_id,
          text: post["message"] || "",
          post_id: post_id,
          channel_id: post["channel_id"]
        }
      end
    end

    include WebSocketHandling
    include EventDispatching

    def parse_post_response(response)
      return {} unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError => parse_error
      log(:warn, "Failed to parse API response: #{parse_error.message}")
      {}
    end
  end
end
