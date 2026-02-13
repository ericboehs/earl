# frozen_string_literal: true

module Earl
  module Mcp
    # Handles permission approval flow: posts a permission request to Mattermost,
    # adds reaction options, and waits for a user reaction to approve or deny.
    class ApprovalHandler
      include Logging

      APPROVE_EMOJIS = %w[+1 white_check_mark].freeze
      DENY_EMOJIS = %w[-1].freeze
      REACTION_EMOJIS = %w[+1 white_check_mark -1].freeze

      def initialize(config:, api_client:)
        @config = config
        @api = api_client
        @allow_all = false
        @mutex = Mutex.new
      end

      def handle(tool_name:, input:)
        return allow_result if @allow_all

        post_id = post_permission_request(tool_name, input)
        return deny_result("Failed to post permission request") unless post_id

        add_reaction_options(post_id)
        decision = wait_for_reaction(post_id)
        delete_permission_post(post_id)
        decision
      end

      private

      def allow_result
        { behavior: "allow", updatedInput: nil }
      end

      def deny_result(reason = "Denied")
        { behavior: "deny", message: reason }
      end

      def post_permission_request(tool_name, input)
        input_summary = format_input(tool_name, input)
        message = ":lock: **Permission Request**\nClaude wants to run: `#{tool_name}`\n```\n#{input_summary}\n```\nReact: :+1: allow once | :white_check_mark: allow all | :-1: deny"

        response = @api.post("/posts", {
          channel_id: @config.platform_channel_id,
          message: message,
          root_id: @config.platform_thread_id
        })

        return unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)["id"]
      end

      def format_input(tool_name, input)
        case tool_name
        when "Bash"
          input["command"].to_s[0..500]
        when "Edit", "Write"
          "#{input['file_path']}\n#{input.fetch('new_string', input.fetch('content', ''))[0..300]}"
        else
          JSON.generate(input)[0..500]
        end
      end

      def add_reaction_options(post_id)
        REACTION_EMOJIS.each do |emoji|
          @api.post("/reactions", {
            user_id: @config.platform_bot_id,
            post_id: post_id,
            emoji_name: emoji
          })
        end
      end

      def wait_for_reaction(post_id)
        timeout_sec = @config.permission_timeout_ms / 1000.0
        deadline = Time.now + timeout_sec

        ws = connect_websocket
        result = poll_for_reaction(ws, post_id, deadline)
        ws&.close rescue nil

        result || deny_result("Timed out waiting for approval")
      end

      def connect_websocket
        ws = WebSocket::Client::Simple.connect(@config.websocket_url)
        token = @config.platform_token
        ws.on(:open) { send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } })) }
        ws
      rescue StandardError => error
        log(:error, "MCP WebSocket connect failed: #{error.message}")
        nil
      end

      def poll_for_reaction(ws, post_id, deadline)
        reaction_queue = Queue.new

        ws&.on(:message) do |msg|
          next unless msg.data && !msg.data.empty?

          begin
            event = JSON.parse(msg.data)
            if event["event"] == "reaction_added"
              reaction_data = JSON.parse(event.dig("data", "reaction") || "{}")
              if reaction_data["post_id"] == post_id
                reaction_queue.push(reaction_data)
              end
            end
          rescue JSON::ParserError
            # ignore
          end
        end

        loop do
          remaining = deadline - Time.now
          return nil if remaining <= 0

          reaction = begin
            reaction_queue.pop(true)
          rescue ThreadError
            sleep 0.5
            nil
          end

          next unless reaction
          next if reaction["user_id"] == @config.platform_bot_id
          next unless allowed_reactor?(reaction["user_id"])

          return process_reaction(reaction["emoji_name"])
        end
      end

      def allowed_reactor?(user_id)
        return true if @config.allowed_users.empty?

        response = @api.get("/users/#{user_id}")
        return false unless response.is_a?(Net::HTTPSuccess)

        user = JSON.parse(response.body)
        @config.allowed_users.include?(user["username"])
      end

      def process_reaction(emoji_name)
        if emoji_name == "white_check_mark"
          @allow_all = true
          allow_result
        elsif APPROVE_EMOJIS.include?(emoji_name)
          allow_result
        elsif DENY_EMOJIS.include?(emoji_name)
          deny_result("Denied by user")
        end
      end

      def delete_permission_post(post_id)
        @api.delete("/posts/#{post_id}")
      rescue StandardError => error
        log(:warn, "Failed to delete permission post #{post_id}: #{error.message}")
      end
    end
  end
end
