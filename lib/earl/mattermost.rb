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
    Callbacks = Struct.new(:on_message, :on_reaction, :on_close, keyword_init: true)

    def initialize(config)
      @config = config
      @api = ApiClient.new(config)
      @connection = Connection.new(ws: nil, channel_ids: Set.new([config.channel_id]))
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

    def on_close(&block)
      @callbacks.on_close = block
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

    def get_channel(channel_id:)
      parse_post_response(@api.get("/channels/#{channel_id}"))
    end

    # File operations extracted to keep class method count under threshold.
    module FileHandling
      # Bundles parameters for creating a post with file attachments.
      FilePost = Data.define(:channel_id, :message, :root_id, :file_ids)

      def download_file(file_id)
        @api.get("/files/#{file_id}")
      end

      def get_file_info(file_id)
        parse_post_response(@api.get("/files/#{file_id}/info"))
      end

      def upload_file(upload)
        parse_post_response(@api.post_multipart("/files", upload))
      end

      def create_post_with_files(file_post)
        parse_post_response(@api.post("/posts", file_post.to_h))
      end
    end

    include FileHandling

    # Fetches all posts in a thread, ordered oldest-first.
    # Returns an array of hashes with :sender, :message, :is_bot.
    def get_thread_posts(thread_id)
      response = @api.get("/posts/#{thread_id}/thread")
      return [] unless response.is_a?(Net::HTTPSuccess)

      data = JSON.parse(response.body)
      posts, order = data.values_at("posts", "order")
      build_thread_posts(posts || {}, order || [])
    rescue JSON::ParserError => error
      log(:warn, "Failed to parse thread posts: #{error.message}")
      []
    end

    private

    def build_thread_posts(posts, order)
      bot_id = config.bot_id
      order.reverse.filter_map do |id|
        format_thread_post(posts[id], bot_id) if posts.key?(id)
      end
    end

    def format_thread_post(post, bot_id)
      from_bot = post.dig("props", "from_bot") == "true"
      message = post["message"] || ""
      user_id = post["user_id"]
      { sender: from_bot ? "EARL" : "user", message: message, is_bot: user_id == bot_id }
    end

    # WebSocket lifecycle methods extracted to reduce class method count.
    module WebSocketHandling
      private

      def setup_websocket_handlers
        websocket_handler_map.each { |event, handler| @connection.ws.on(event, &handler) }
      end

      def websocket_handler_map
        msg_handler = method(:handle_websocket_message)
        close_handler = method(:handle_websocket_close)
        auth = method(:auth_payload)
        {
          open: -> { send(JSON.generate(auth.call)) },
          message: ->(msg) { msg_handler.call(msg) },
          error: ->(error) { Earl.logger.error "WebSocket error: #{error.message}" },
          close: ->(event) { close_handler.call(event) }
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

        log(:debug, "WS event: #{event["event"] || event.keys.first}")
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
        @callbacks.on_close&.call
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
        dispatch_reaction(reaction)
      rescue JSON::ParserError => error
        log(:warn, "Failed to parse reaction data: #{error.message}")
      end

      def dispatch_reaction(reaction)
        user_id, post_id, emoji_name = reaction.values_at("user_id", "post_id", "emoji_name")
        return if user_id == config.bot_id

        @callbacks.on_reaction&.call(user_id: user_id, post_id: post_id, emoji_name: emoji_name)
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
        log(:info,
            "Message from @#{params[:sender_name]} in thread #{params[:thread_id][0..7]}: #{params[:text][0..80]}")
        @callbacks.on_message&.call(**params)
      end

      def build_message_params(event, post)
        post_id, root_id, message, channel_id, file_ids =
          post.values_at("id", "root_id", "message", "channel_id", "file_ids")
        {
          sender_name: extract_sender(event),
          thread_id: root_id.to_s.empty? ? post_id : root_id,
          text: message || "",
          post_id: post_id,
          channel_id: channel_id,
          file_ids: file_ids || []
        }
      end

      def extract_sender(event)
        event.dig("data", "sender_name")&.delete_prefix("@") || "unknown"
      end
    end

    include WebSocketHandling
    include EventDispatching

    def parse_post_response(response)
      return {} unless successful?(response)

      safe_json_parse(response.body)
    end

    def successful?(response)
      response.is_a?(Net::HTTPSuccess)
    end

    def safe_json_parse(body)
      JSON.parse(body)
    rescue JSON::ParserError => error
      log(:warn, "Failed to parse API response: #{error.message}")
      {}
    end
  end
end
