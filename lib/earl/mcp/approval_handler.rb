# frozen_string_literal: true

require "set"

module Earl
  module Mcp
    # Handles permission approval flow: posts a permission request to Mattermost,
    # adds reaction options, and waits for a user reaction to approve or deny.
    # Tracks per-tool approvals persisted to disk per-thread (stored in
    # allowed_tools/{thread_id}.json) so "always allow" applies to specific
    # tool names (e.g., Bash) rather than blanket approval.
    class ApprovalHandler
      include Logging
      include HandlerBase

      TOOL_NAME = "permission_prompt"
      TOOL_NAMES = [ TOOL_NAME ].freeze
      ALLOWED_TOOLS_DIR = File.expand_path("~/.config/earl/allowed_tools")

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

      # --- Handler interface for Server multi-handler routing ---

      def tool_definitions
        [
          {
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
          }
        ]
      end

      def call(_name, arguments)
        request = ToolRequest.new(
          tool_name: arguments["tool_name"] || "unknown",
          input: arguments["input"] || {}
        )
        result = handle(request)
        { content: [ { type: "text", text: JSON.generate(result) } ] }
      end

      # --- Core permission flow (internal implementation) ---

      def handle(request)
        if @mutex.synchronize { @allowed_tools.include?(request.tool_name) }
          log(:info, "Auto-allowing #{request.tool_name} (previously approved)")
          return allow_result(request.input)
        end

        post_id = post_permission_request(request)
        return deny_result("Failed to post permission request") unless post_id

        add_reaction_options(post_id)
        decision = wait_for_reaction(post_id, request)
        delete_permission_post(post_id)
        decision
      end

      private

      def allow_result(input)
        { behavior: "allow", updatedInput: input }
      end

      def deny_result(reason = "Denied")
        { behavior: "deny", message: reason }
      end

      def post_permission_request(request)
        input_summary = format_input(request.tool_name, request.input)
        message = ":lock: **Permission Request**\nClaude wants to run: `#{request.tool_name}`\n```\n#{input_summary}\n```\n" \
                  "React: :+1: allow once | :white_check_mark: always allow `#{request.tool_name}` | :-1: deny"

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

      # WebSocket-based reaction polling for permission decisions.
      module ReactionPolling
        private

        def wait_for_reaction(post_id, request)
          timeout_sec = @config.permission_timeout_ms / 1000.0
          deadline = Time.now + timeout_sec

          ws = connect_websocket
          unless ws
            log(:error, "WebSocket connection failed, denying permission")
            return deny_result("WebSocket connection failed")
          end

          result = poll_for_reaction(ws, post_id, request, deadline)

          result || deny_result("Timed out waiting for approval")
        ensure
          begin
            ws&.close
          rescue StandardError
            nil
          end
        end

        def connect_websocket
          ws = WebSocket::Client::Simple.connect(@config.websocket_url)
          token = @config.platform_token
          ws_ref = ws
          ws.on(:open) { ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } })) }
          ws
        rescue StandardError => error
          log(:error, "MCP WebSocket connect failed: #{error.message}")
          nil
        end

        def poll_for_reaction(ws, post_id, request, deadline)
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
              log(:debug, "MCP approval: skipped unparsable WebSocket message")
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

            return process_reaction(reaction["emoji_name"], request)
          end
        end

        def allowed_reactor?(user_id)
          return true if @config.allowed_users.empty?

          response = @api.get("/users/#{user_id}")
          return false unless response.is_a?(Net::HTTPSuccess)

          user = JSON.parse(response.body)
          @config.allowed_users.include?(user["username"])
        end

        def process_reaction(emoji_name, request)
          if Reactions::APPROVE.include?(emoji_name)
            if emoji_name == "white_check_mark"
              @mutex.synchronize { @allowed_tools.add(request.tool_name) }
              save_allowed_tools
            end
            allow_result(request.input)
          elsif Reactions::DENY.include?(emoji_name)
            deny_result("Denied by user")
          end
        end
      end

      # Persistence for per-tool allowed list.
      module AllowedToolsPersistence
        private

        def load_allowed_tools
          path = allowed_tools_path
          return Set.new unless File.exist?(path)

          Set.new(JSON.parse(File.read(path)))
        rescue JSON::ParserError, Errno::ENOENT
          Set.new
        end

        def save_allowed_tools
          FileUtils.mkdir_p(ALLOWED_TOOLS_DIR)
          File.write(allowed_tools_path, JSON.generate(@allowed_tools.to_a))
        rescue StandardError => error
          log(:warn, "Failed to save allowed tools: #{error.message}")
        end

        def allowed_tools_path
          File.join(ALLOWED_TOOLS_DIR, "#{@config.platform_thread_id}.json")
        end
      end

      include ReactionPolling
      include AllowedToolsPersistence
    end
  end
end
