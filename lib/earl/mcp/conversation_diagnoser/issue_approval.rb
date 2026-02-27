# frozen_string_literal: true

module Earl
  module Mcp
    class ConversationDiagnoser
      # Reaction-based approval flow before GitHub issue creation.
      # Posts the analysis to the Mattermost thread with 👍/👎 reactions,
      # then polls via WebSocket for a user decision.
      module IssueApproval
        APPROVE_EMOJI = %w[+1].freeze
        DENY_EMOJI = %w[-1].freeze
        REACTION_EMOJI = (APPROVE_EMOJI + DENY_EMOJI).freeze
        APPROVAL_TIMEOUT_MS = 86_400_000

        private

        def request_issue_approval(analysis_text, thread_id)
          post_id = post_analysis(analysis_text, thread_id)
          return :error unless post_id

          add_approval_reactions(post_id)
          poll_for_approval(post_id)
        end

        def post_analysis(text, thread_id)
          message = ":mag: **Conversation Analysis**\n\n#{text}\n\n" \
                    "React :+1: to create a GitHub issue, :-1: to skip."
          response = @api.post("/posts", {
                                 channel_id: @config.platform_channel_id,
                                 message: message,
                                 root_id: thread_id
                               })
          return unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)["id"]
        end

        def add_approval_reactions(post_id)
          REACTION_EMOJI.each do |emoji|
            @api.post("/reactions", {
                        user_id: @config.platform_bot_id,
                        post_id: post_id,
                        emoji_name: emoji
                      })
          end
        end
      end

      # WebSocket-based polling for issue approval reactions.
      # NOTE: websocket-client-simple uses instance_exec for on() callbacks,
      # changing self to the WebSocket object. Capture method refs as closures
      # to avoid NoMethodError on our handler methods.
      module ApprovalPolling
        # Bundles WebSocket message handler dependencies for reaction parsing.
        ApprovalContext = Data.define(:ws, :post_id, :extractor, :queue) do
          def enqueue(msg_data)
            reaction = extractor.call(msg_data)
            queue.push(reaction) if reaction && reaction["post_id"] == post_id
          end
        end

        private

        def poll_for_approval(post_id)
          deadline = Time.now + (IssueApproval::APPROVAL_TIMEOUT_MS / 1000.0)
          websocket = connect_approval_websocket
          return :error unless websocket

          queue = register_approval_listener(websocket, post_id)
          approval_poll_loop(queue, deadline)
        rescue StandardError => error
          log(:error, "Issue approval error: #{error.message}")
          :error
        ensure
          safe_close_websocket(websocket)
        end

        def connect_approval_websocket
          ws = WebSocket::Client::Simple.connect(@config.websocket_url)
          authenticate_approval_websocket(ws)
          ws
        rescue StandardError => error
          log(:error, "Issue approval WebSocket failed: #{error.message}")
          nil
        end

        def authenticate_approval_websocket(websocket)
          token = @config.platform_token
          ws_ref = websocket
          websocket.on(:open) do
            ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge",
                                        data: { token: token } }))
          end
        end

        def register_approval_listener(websocket, target_post_id)
          queue = Queue.new
          ctx = build_approval_context(websocket, target_post_id, queue)
          ws_ref = websocket
          enqueue = method(:safe_enqueue_approval)
          ws_ref.on(:message) do |msg|
            msg.type == :ping ? ws_ref.send(nil, type: :pong) : enqueue.call(ctx, msg.data)
          end
          queue
        end

        def build_approval_context(websocket, target_post_id, queue)
          ApprovalContext.new(
            ws: websocket, post_id: target_post_id,
            extractor: method(:extract_approval_reaction), queue: queue
          )
        end

        def safe_enqueue_approval(ctx, msg_data)
          ctx.enqueue(msg_data)
        rescue StandardError => error
          log(:debug, "Issue approval: error processing message: #{error.message}")
        end

        def extract_approval_reaction(data)
          return unless data && !data.empty?

          parsed = JSON.parse(data)
          event_name, event_data = parsed.values_at("event", "data")
          return unless event_name == "reaction_added"

          JSON.parse(event_data&.dig("reaction") || "{}")
        rescue JSON::ParserError
          nil
        end

        def approval_poll_loop(queue, deadline)
          loop do
            return :denied if (deadline - Time.now) <= 0

            reaction = dequeue_approval(queue)
            next unless valid_approval_reaction?(reaction)

            return classify_approval(reaction["emoji_name"])
          end
        end

        def dequeue_approval(queue)
          queue.pop(true)
        rescue ThreadError
          sleep 0.5
          nil
        end

        def safe_close_websocket(websocket)
          websocket&.close
        rescue IOError, Errno::ECONNRESET
          nil
        end
      end

      # Reaction classification and user validation for issue approval decisions.
      module ApprovalClassification
        private

        def valid_approval_reaction?(reaction)
          return false unless reaction

          user_id = reaction["user_id"]
          user_id != @config.platform_bot_id && allowed_approval_reactor?(user_id)
        end

        def allowed_approval_reactor?(user_id)
          allowed = @config.allowed_users
          return true if allowed.empty?

          response = @api.get("/users/#{user_id}")
          return false unless response.is_a?(Net::HTTPSuccess)

          user = JSON.parse(response.body)
          allowed.include?(user["username"])
        end

        def classify_approval(emoji_name)
          return :approved if IssueApproval::APPROVE_EMOJI.include?(emoji_name)

          :denied if IssueApproval::DENY_EMOJI.include?(emoji_name)
        end
      end
    end
  end
end
