# frozen_string_literal: true

require "websocket-client-simple"

module Earl
  class Mattermost
    attr_reader :config

    def initialize(config)
      @config = config
      @on_message = nil
    end

    def on_message(&block)
      @on_message = block
    end

    def connect
      ws_url = config.websocket_url
      token = config.bot_token
      bot_id = config.bot_id
      channel_id = config.channel_id
      logger = Earl.logger
      mm = self # reference for reading @on_message at call time

      @ws = WebSocket::Client::Simple.connect(ws_url)

      @ws.on :open do
        logger.info "WebSocket connected, sending auth challenge"
        send(JSON.generate({
          seq: 1,
          action: "authentication_challenge",
          data: { token: token }
        }))
      end

      @ws.on :message do |msg|
        begin
          # Respond to pings to keep connection alive
          if msg.type == :ping
            logger.debug "WS ping received, sending pong"
            send(nil, type: :pong)
          end

          data = msg.data
          logger.debug "WS raw: type=#{msg.type rescue 'N/A'} data_size=#{data&.size}"
          if data && !data.empty?
            event = JSON.parse(data)
            logger.debug "WS event: #{event['event'] || event.keys.first}"

            if event["event"] == "hello"
              logger.info "Authenticated to Mattermost"
            elsif event["event"] == "posted"
              post_data = event.dig("data", "post")
              if post_data
                post = JSON.parse(post_data)

                if post["user_id"] == bot_id
                  # Skip: bot's own message
                elsif post["channel_id"] != channel_id
                  # Skip: message from another channel
                else
                  sender_name = event.dig("data", "sender_name")&.delete_prefix("@") || "unknown"
                  thread_id = post["root_id"].to_s.empty? ? post["id"] : post["root_id"]
                  message_text = post["message"] || ""

                  logger.info "Message from @#{sender_name} in thread #{thread_id[0..7]}: #{message_text[0..80]}"
                  on_msg = mm.instance_variable_get(:@on_message)
                  on_msg&.call(sender_name: sender_name, thread_id: thread_id, text: message_text, post_id: post["id"])
                end
              end
            end
          end
        rescue JSON::ParserError => e
          logger.warn "Failed to parse WebSocket message: #{e.message}"
        rescue => e
          logger.error "Error handling WebSocket message: #{e.class}: #{e.message}"
          logger.error e.backtrace.first(5).join("\n")
        end
      end

      @ws.on :error do |e|
        logger.error "WebSocket error: #{e.message}"
      end

      @ws.on :close do |e|
        logger.warn "WebSocket closed: #{e&.code} #{e&.reason}"
        logger.warn "EARL will exit — restart process to reconnect"
        exit 1
      end
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

    def api_request(method_class, path, body)
      uri = URI.parse(config.api_url(path))
      req = method_class.new(uri)
      req["Authorization"] = "Bearer #{config.bot_token}"
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 15
      response = http.request(req)

      unless response.is_a?(Net::HTTPSuccess)
        Earl.logger.error "Mattermost API #{req.method} #{path} failed: #{response.code} #{response.body[0..200]}"
      end

      response
    end

    def api_post(path, body)
      api_request(Net::HTTP::Post, path, body)
    end

    def api_put(path, body)
      api_request(Net::HTTP::Put, path, body)
    end
  end
end
