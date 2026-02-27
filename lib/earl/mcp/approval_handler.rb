# frozen_string_literal: true

module Earl
  module Mcp
    # Handles permission approval flow: posts a permission request to Mattermost,
    # adds reaction options, and waits for a user reaction to approve or deny.
    # Tracks per-tool approvals persisted to a global file (allowed_tools.json)
    # so "always allow" applies across all threads.
    class ApprovalHandler
      include Logging
      include HandlerBase

      TOOL_NAME = "permission_prompt"
      TOOL_NAMES = [TOOL_NAME].freeze

      INPUT_FORMATTERS = {
        "Bash" => ->(input) { input["command"].to_s[0..500] },
        "Edit" => lambda { |input|
          "#{input["file_path"]}\n#{input.fetch("new_string", input.fetch("content", ""))[0..300]}"
        },
        "Write" => lambda { |input|
          "#{input["file_path"]}\n#{input.fetch("new_string", input.fetch("content", ""))[0..300]}"
        }
      }.freeze

      TOOL_SCHEMA = {
        name: TOOL_NAME,
        description: "Request permission to execute a tool",
        inputSchema: {
          type: "object",
          properties: {
            tool_name: { type: "string", description: "Name of the tool requesting permission" },
            input: { type: "object", description: "The tool's input parameters" }
          },
          required: %w[tool_name input]
        }
      }.freeze

      def self.allowed_tools_path
        @allowed_tools_path ||= File.join(Earl.config_root, "allowed_tools.json")
      end

      # Bundles tool_name and input that travel together through the approval flow.
      ToolRequest = Data.define(:tool_name, :input)

      # Reaction emoji sets for the permission approval flow.
      module Reactions
        APPROVE = %w[+1 white_check_mark].freeze
        DENY = %w[-1].freeze
        ALL = %w[+1 white_check_mark -1].freeze
      end

      def initialize(config:, api_client:)
        @config = config
        @api = api_client
        @allowed_tools = load_allowed_tools
        @mutex = Mutex.new
      end

      def tool_definitions
        [TOOL_SCHEMA]
      end

      def call(_name, arguments)
        request = build_request(arguments)
        format_handler_result(handle(request))
      end

      def handle(request)
        return allow_result(request.input) if auto_approved?(request.tool_name)

        post_and_wait(request)
      end

      private

      def build_request(arguments)
        ToolRequest.new(
          tool_name: arguments["tool_name"] || "unknown",
          input: arguments["input"] || {}
        )
      end

      def auto_approved?(tool_name)
        return false unless @mutex.synchronize { @allowed_tools.include?(tool_name) }

        log(:info, "Auto-allowing #{tool_name} (previously approved)")
        true
      end

      def post_and_wait(request)
        post_id = post_permission_request(request)
        return deny_result("Failed to post permission request") unless post_id

        add_reaction_options(post_id)
        decision = wait_for_reaction(post_id, request)
        delete_permission_post(post_id)
        decision
      end

      def allow_result(input)
        { behavior: "allow", updatedInput: input }
      end

      def deny_result(reason = "Denied")
        { behavior: "deny", message: reason }
      end

      def format_handler_result(result)
        { content: [{ type: "text", text: JSON.generate(result) }] }
      end

      # Mattermost posting for permission requests.
      module PermissionPosting
        private

        def post_permission_request(request)
          message = permission_message(request)
          response = @api.post("/posts", {
                                 channel_id: @config.platform_channel_id,
                                 message: message,
                                 root_id: @config.platform_thread_id
                               })

          return unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)["id"]
        end

        def permission_message(request)
          tool_name = request.tool_name
          input_summary = format_input(tool_name, request.input)
          format_permission_text(tool_name, input_summary)
        end

        def format_permission_text(tool_name, input_summary)
          ":lock: **Permission Request**\nClaude wants to run: `#{tool_name}`\n```\n#{input_summary}\n```\n" \
            "React: :+1: allow once | :white_check_mark: always allow `#{tool_name}` | :-1: deny"
        end

        def format_input(tool_name, input)
          formatter = INPUT_FORMATTERS[tool_name]
          formatter ? formatter.call(input) : JSON.generate(input)[0..500]
        end

        def add_reaction_options(post_id)
          Reactions::ALL.each do |emoji|
            @api.post("/reactions", {
                        user_id: @config.platform_bot_id,
                        post_id: post_id,
                        emoji_name: emoji
                      })
          end
        end

        def delete_permission_post(post_id)
          @api.delete("/posts/#{post_id}")
        rescue StandardError => error
          log(:warn, "Failed to delete permission post #{post_id}: #{error.message}")
        end
      end

      # WebSocket-based reaction polling for permission decisions.
      # NOTE: websocket-client-simple uses instance_exec for on() callbacks,
      # changing self to the WebSocket object. Capture method refs as closures
      # to avoid NoMethodError on our handler methods.
      module ReactionPolling
        # Bundles poll parameters into a single context object.
        PollContext = Data.define(:ws, :post_id, :request, :deadline)
        # Bundles WebSocket message handler dependencies.
        MessageHandlerContext = Data.define(:ws, :post_id, :extractor, :queue) do
          def enqueue(msg_data)
            reaction_data = extractor.call(msg_data)
            queue.push(reaction_data) if reaction_data && reaction_data["post_id"] == post_id
          end
        end

        private

        def wait_for_reaction(post_id, request)
          deadline = Time.now + (@config.permission_timeout_ms / 1000.0)
          websocket = connect_websocket

          return deny_result("WebSocket connection failed") unless websocket

          context = PollContext.new(ws: websocket, post_id: post_id, request: request, deadline: deadline)
          poll_for_reaction(context) || deny_result("Timed out waiting for approval")
        rescue StandardError => error
          deny_result("Error waiting for approval: #{error.message}")
        ensure
          safe_close(websocket)
        end

        def safe_close(websocket)
          websocket&.close
        rescue IOError, Errno::ECONNRESET
          nil
        end

        def connect_websocket
          ws = WebSocket::Client::Simple.connect(@config.websocket_url)
          token = @config.platform_token
          ws_ref = ws
          ws.on(:open) do
            ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } }))
          end
          ws
        rescue StandardError => error
          log(:error, "MCP WebSocket connect failed: #{error.message}")
          nil
        end

        def poll_for_reaction(context)
          reaction_queue = Queue.new
          register_reaction_listener(context, reaction_queue)
          poll_reaction_loop(context, reaction_queue)
        end

        def register_reaction_listener(context, reaction_queue)
          ws_ref, target_post_id = context.deconstruct
          handler_ctx = build_handler_context(ws_ref, target_post_id, reaction_queue)
          enqueue = method(:enqueue_reaction)
          ws_ref&.on(:message) do |msg|
            msg.type == :ping ? ws_ref.send(nil, type: :pong) : enqueue.call(handler_ctx, msg.data)
          end
        end

        def build_handler_context(ws_ref, target_post_id, reaction_queue)
          MessageHandlerContext.new(
            ws: ws_ref, post_id: target_post_id,
            extractor: method(:extract_reaction_data), queue: reaction_queue
          )
        end

        def enqueue_reaction(ctx, msg_data)
          ctx.enqueue(msg_data)
        rescue StandardError => error
          log(:debug, "MCP approval: error processing WebSocket message: #{error.message}")
        end

        def extract_reaction_data(data)
          return unless data && !data.empty?

          parsed = JSON.parse(data)
          event_name, event_data = parsed.values_at("event", "data")
          return unless event_name == "reaction_added"

          JSON.parse(event_data&.dig("reaction") || "{}")
        rescue JSON::ParserError
          log(:debug, "MCP approval: skipped unparsable WebSocket message")
          nil
        end

        def poll_reaction_loop(context, reaction_queue)
          loop do
            return nil if (context.deadline - Time.now) <= 0

            reaction = dequeue_reaction(reaction_queue)
            next unless valid_user_reaction?(reaction)

            return process_reaction(reaction["emoji_name"], context.request)
          end
        end

        def dequeue_reaction(reaction_queue)
          reaction_queue.pop(true)
        rescue ThreadError
          sleep 0.5
          nil
        end
      end

      # Reaction classification and user validation for permission decisions.
      module ReactionClassification
        private

        def valid_user_reaction?(reaction)
          return false unless reaction

          user_id = reaction["user_id"]
          user_id != @config.platform_bot_id && allowed_reactor?(user_id)
        end

        def allowed_reactor?(user_id)
          allowed = @config.allowed_users
          return true if allowed.empty?

          response = @api.get("/users/#{user_id}")
          return false unless response.is_a?(Net::HTTPSuccess)

          user = JSON.parse(response.body)
          allowed.include?(user["username"])
        end

        def process_reaction(emoji_name, request)
          if Reactions::APPROVE.include?(emoji_name)
            persist_always_allow(request.tool_name) if emoji_name == "white_check_mark"
            allow_result(request.input)
          elsif Reactions::DENY.include?(emoji_name)
            deny_result("Denied by user")
          end
        end

        def persist_always_allow(tool_name)
          @mutex.synchronize { @allowed_tools.add(tool_name) }
          save_allowed_tools
        end
      end

      # Persistence for globally allowed tool list.
      module AllowedToolsPersistence
        private

        def load_allowed_tools
          path = self.class.allowed_tools_path
          return Set.new unless File.exist?(path)

          Set.new(JSON.parse(File.read(path)))
        rescue JSON::ParserError, Errno::ENOENT
          Set.new
        end

        def save_allowed_tools
          File.write(self.class.allowed_tools_path, JSON.generate(@allowed_tools.to_a))
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOSPC, IOError => error
          log(:warn, "Failed to save allowed tools: #{error.message}")
        end
      end

      include PermissionPosting
      include ReactionPolling
      include ReactionClassification
      include AllowedToolsPersistence
    end
  end
end
