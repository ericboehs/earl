# frozen_string_literal: true

require "securerandom"
require "shellwords"

module Earl
  module Mcp
    # MCP handler for spawning PEARL (Protected EARL) agents — Docker-isolated
    # Claude sessions with scoped credentials. Conforms to the Server handler
    # interface: tool_definitions, handles?, call.
    #
    # Actions:
    #   list_agents — discover available agent profiles
    #   run         — spawn a PEARL agent in the pearl-agents tmux session
    class PearlHandler
      include Logging
      include HandlerBase

      TOOL_NAME = "manage_pearl_agents"
      TOOL_NAMES = [TOOL_NAME].freeze
      VALID_ACTIONS = %w[list_agents run].freeze
      TMUX_SESSION = "pearl-agents"

      # Bundles run parameters that travel together through the confirmation and creation flow.
      RunRequest = Data.define(:agent, :prompt, :window_name) do
        def target
          "#{TMUX_SESSION}:#{window_name}"
        end

        def pearl_command(pearl_bin)
          "#{Shellwords.shellescape(pearl_bin)} #{Shellwords.shellescape(agent)} -p #{Shellwords.shellescape(prompt)}"
        end
      end

      def initialize(config:, api_client:, tmux_store:, tmux_adapter: Tmux)
        @config = config
        @api = api_client
        @tmux_store = tmux_store
        @tmux = tmux_adapter
      end

      def tool_definitions
        [tool_definition]
      end

      def call(name, arguments)
        return unless handles?(name)

        error = validate_action(arguments)
        return error if error

        send("handle_#{arguments["action"]}", arguments)
      end

      private

      def validate_action(arguments)
        action = arguments["action"]
        valid_list = VALID_ACTIONS.join(", ")
        return text_content("Error: action is required (#{valid_list})") unless action

        text_content("Error: unknown action '#{action}'. Valid: #{valid_list}") unless VALID_ACTIONS.include?(action)
      end

      def text_content(text)
        { content: [{ type: "text", text: text }] }
      end

      # Discovers available agent profiles from the pearl-agents repo.
      module AgentDiscovery
        private

        def handle_list_agents(_arguments)
          agents_dir = find_agents_dir
          unless agents_dir
            return text_content(
              "Error: pearl-agents repo not found. Set PEARL_BIN or add pearl to PATH."
            )
          end

          agents = discover_agents(agents_dir)
          return text_content("No agent profiles found in #{agents_dir}") if agents.empty?

          lines = agents.map { |agent| format_agent(agent) }
          text_content("**Available PEARL Agents (#{agents.size}):**\n\n#{lines.join("\n")}")
        end

        def find_agents_dir
          repo = pearl_agents_repo
          return unless repo

          dir = File.join(repo, "agents")
          dir if Dir.exist?(dir)
        end

        def pearl_agents_repo
          pearl = resolve_pearl_bin
          return unless pearl

          repo = File.dirname(pearl, 2)
          repo if File.exist?(File.join(repo, "agents"))
        end

        def discover_agents(agents_dir)
          Dir.children(agents_dir)
             .select { |name| agent_profile?(agents_dir, name) }
             .sort
             .map { |name| build_agent_info(agents_dir, name) }
        end

        def agent_profile?(agents_dir, name)
          name != "base" && File.exist?(File.join(agents_dir, name, "Dockerfile"))
        end

        def build_agent_info(agents_dir, name)
          has_skills = Dir.exist?(File.join(agents_dir, name, "skills"))
          { name: name, has_skills: has_skills }
        end

        def format_agent(agent)
          skills_badge = agent[:has_skills] ? " (skills: yes)" : ""
          "- `#{agent[:name]}`#{skills_badge}"
        end
      end

      # Spawns PEARL agents in the pearl-agents tmux session with Mattermost confirmation.
      module AgentRunner
        private

        def handle_run(arguments)
          error = validate_run_args(arguments)
          return error if error

          request = build_run_request(arguments)
          execute_run(request)
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end

        def validate_run_args(arguments)
          agent = arguments["agent"]
          prompt = arguments["prompt"]
          return text_content("Error: agent is required for run") unless agent && !agent.strip.empty?
          return text_content("Error: prompt is required for run") unless prompt && !prompt.strip.empty?

          validate_pearl_bin || validate_agent_exists(agent)
        end

        def validate_pearl_bin
          text_content("Error: `pearl` CLI not found. Set PEARL_BIN or add pearl to PATH.") unless resolve_pearl_bin
        end

        def validate_agent_exists(agent)
          agents_dir = find_agents_dir
          return unless agents_dir
          return if agent_profile?(agents_dir, agent)

          available = discover_agents(agents_dir).map { |profile| profile[:name] }.join(", ")
          text_content("Error: unknown agent '#{agent}'. Available: #{available}")
        end

        def build_run_request(arguments)
          agent = arguments["agent"]
          prompt = arguments["prompt"]
          window_name = "#{agent}-#{SecureRandom.hex(2)}"
          RunRequest.new(agent: agent, prompt: prompt, window_name: window_name)
        end

        def execute_run(request)
          case request_run_confirmation(request)
          when :approved then create_pearl_session(request)
          when :error then text_content("Error: run confirmation failed (could not post or connect to Mattermost)")
          else text_content("Run denied by user.")
          end
        end

        def create_pearl_session(request)
          ensure_tmux_session
          command = request.pearl_command(resolve_pearl_bin)
          @tmux.create_window(session: TMUX_SESSION, name: request.window_name, command: command)
          persist_session_info(request)
          format_run_result(request.agent, request.target, request.prompt)
        end

        def ensure_tmux_session
          @tmux.create_session(name: TMUX_SESSION) unless @tmux.session_exists?(TMUX_SESSION)
        end

        def persist_session_info(request)
          channel_id = @config.platform_channel_id
          thread_id = @config.platform_thread_id
          info = TmuxSessionStore::TmuxSessionInfo.new(
            name: request.target, channel_id: channel_id,
            thread_id: thread_id,
            working_dir: nil, prompt: request.prompt, created_at: Time.now.iso8601
          )
          @tmux_store.save(info)
        end

        def format_run_result(agent, target, prompt)
          text_content(
            "Spawned PEARL agent `#{agent}` in tmux window `#{target}`.\n" \
            "- **Prompt:** #{prompt}\n" \
            "- **Monitor:** Use `manage_tmux_sessions` with target `#{target}` to capture output or check status."
          )
        end
      end

      # Spawn confirmation via Mattermost reactions.
      # Reuses the same pattern as TmuxHandler::SpawnConfirmation.
      module RunConfirmation
        APPROVE_EMOJIS = %w[+1 white_check_mark].freeze
        DENY_EMOJIS = %w[-1].freeze
        REACTION_EMOJIS = (APPROVE_EMOJIS + DENY_EMOJIS).freeze

        private

        def request_run_confirmation(request)
          post_id = post_confirmation_request(request)
          return :error unless post_id

          add_reaction_options(post_id)
          wait_for_confirmation(post_id)
        ensure
          delete_confirmation_post(post_id) if post_id
        end

        def post_confirmation_request(request)
          message = build_confirmation_message(request)
          post_to_channel(message)
        rescue IOError, JSON::ParserError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
          log(:error, "Failed to post PEARL run confirmation: #{error.message}")
          nil
        end

        def build_confirmation_message(request)
          ":whale: **PEARL Agent Request**\n" \
            "Claude wants to run agent `#{request.agent}`\n" \
            "- **Prompt:** #{request.prompt}\n" \
            "- **Window:** `#{request.target}`\n" \
            "React: :+1: approve | :-1: deny"
        end

        def post_to_channel(message)
          response = @api.post("/posts", confirmation_post_body(message))
          return log_post_failure(response) unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)["id"]
        end

        def confirmation_post_body(message)
          { channel_id: @config.platform_channel_id,
            message: message,
            root_id: @config.platform_thread_id }
        end

        def log_post_failure(response)
          log(:warn, "Failed to post PEARL confirmation (HTTP #{response.class})")
          nil
        end

        def add_reaction_options(post_id)
          REACTION_EMOJIS.each do |emoji|
            response = @api.post("/reactions", {
                                   user_id: @config.platform_bot_id,
                                   post_id: post_id,
                                   emoji_name: emoji
                                 })
            log(:warn, "Failed to add reaction #{emoji}") unless response.is_a?(Net::HTTPSuccess)
          end
        rescue IOError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
          log(:error, "Failed to add reaction options: #{error.message}")
        end

        def delete_confirmation_post(post_id)
          @api.delete("/posts/#{post_id}")
        rescue StandardError => error
          log(:warn, "Failed to delete PEARL confirmation: #{error.message}")
        end
      end

      # WebSocket-based polling for run confirmation reactions.
      # NOTE: websocket-client-simple uses instance_exec for on() callbacks,
      # changing self to the WebSocket object. Capture method refs as closures
      # to avoid NoMethodError on our handler methods.
      module RunPolling
        # Bundles WebSocket message handler dependencies for ping/pong and reaction parsing.
        MessageHandlerContext = Data.define(:ws, :post_id, :extractor, :queue)

        private

        def wait_for_confirmation(post_id)
          deadline = confirmation_deadline

          websocket = connect_websocket
          return :error unless websocket

          queue = build_reaction_queue(websocket, post_id)
          await_reaction(queue, deadline)
        rescue StandardError => error
          log(:error, "PEARL confirmation error: #{error.message}")
          :error
        ensure
          close_websocket(websocket)
        end

        def confirmation_deadline
          Time.now + (@config.permission_timeout_ms / 1000.0)
        end

        def close_websocket(websocket)
          websocket&.close
        rescue IOError, Errno::ECONNRESET
          nil
        end

        def connect_websocket
          websocket = WebSocket::Client::Simple.connect(@config.websocket_url)
          authenticate_websocket(websocket)
          websocket
        rescue IOError, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH => error
          log(:error, "PEARL confirmation WebSocket failed: #{error.message}")
          nil
        end

        def authenticate_websocket(websocket)
          token = @config.platform_token
          ws_ref = websocket
          websocket.on(:open) do
            ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } }))
          end
        end

        def build_reaction_queue(websocket, target_post_id)
          queue = Queue.new
          ws_ref = websocket
          handler_ctx = build_handler_context(ws_ref, target_post_id, queue)
          enqueue = method(:enqueue_reaction)
          ws_ref.on(:message) do |msg|
            msg.type == :ping ? ws_ref.send(nil, type: :pong) : enqueue.call(handler_ctx, msg)
          end
          queue
        end

        def build_handler_context(ws_ref, target_post_id, queue)
          MessageHandlerContext.new(
            ws: ws_ref, post_id: target_post_id,
            extractor: method(:parse_reaction_event), queue: queue
          )
        end

        def enqueue_reaction(ctx, msg)
          reaction_data = ctx.extractor.call(msg)
          ctx.queue.push(reaction_data) if reaction_data && reaction_data["post_id"] == ctx.post_id
        end

        def parse_reaction_event(msg)
          raw = msg.data
          return unless raw && !raw.empty?

          parsed = JSON.parse(raw)
          event_name, nested_data = parsed.values_at("event", "data")
          return unless event_name == "reaction_added"

          JSON.parse(nested_data&.dig("reaction") || "{}")
        rescue JSON::ParserError
          log(:debug, "PEARL confirmation: skipped unparsable WebSocket message")
          nil
        end

        def await_reaction(queue, deadline)
          loop do
            return :denied if (deadline - Time.now) <= 0

            reaction = dequeue_reaction(queue)
            next unless reaction

            result = classify_reaction(reaction)
            return result if result
          end
        end

        def dequeue_reaction(queue)
          queue.pop(true)
        rescue ThreadError
          sleep 0.5
          nil
        end

        def classify_reaction(reaction)
          user_id = reaction["user_id"]
          return if user_id == @config.platform_bot_id
          return unless allowed_reactor?(user_id)

          emoji = reaction["emoji_name"]
          return :approved if RunConfirmation::APPROVE_EMOJIS.include?(emoji)

          :denied if RunConfirmation::DENY_EMOJIS.include?(emoji)
        end

        def allowed_reactor?(user_id)
          allowed = @config.allowed_users
          return true if allowed.empty?

          response = @api.get("/users/#{user_id}")
          return false unless response.is_a?(Net::HTTPSuccess)

          user = JSON.parse(response.body)
          allowed.include?(user["username"])
        end
      end

      # Tool definition schema.
      module ToolDefinitionBuilder
        private

        def tool_definition
          {
            name: TOOL_NAME,
            description: pearl_tool_description,
            inputSchema: pearl_input_schema
          }
        end

        def pearl_tool_description
          "Manage PEARL (Protected EARL) Docker-isolated Claude agents. " \
            "List available agent profiles or spawn an agent in the pearl-agents tmux session."
        end

        def pearl_input_schema
          { type: "object", properties: pearl_properties, required: %w[action] }
        end

        def pearl_properties
          {
            action: action_property,
            agent: { type: "string", description: "Agent profile name (e.g., 'code'). Required for run." },
            prompt: { type: "string", description: "Prompt for the PEARL agent session. Required for run." }
          }
        end

        def action_property
          { type: "string", enum: VALID_ACTIONS, description: "Action to perform" }
        end
      end

      # Resolves the pearl CLI binary path.
      module PearlBinResolver
        private

        def resolve_pearl_bin
          ENV.fetch("PEARL_BIN", nil) || find_pearl_in_path
        end

        def find_pearl_in_path
          output, status = Open3.capture2e("which", "pearl")
          status.success? ? output.strip : nil
        rescue Errno::ENOENT
          nil
        end
      end

      include AgentDiscovery
      include AgentRunner
      include RunConfirmation
      include RunPolling
      include ToolDefinitionBuilder
      include PearlBinResolver
    end
  end
end
