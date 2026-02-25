# frozen_string_literal: true

require "securerandom"
require "shellwords"

module Earl
  module Mcp
    # MCP handler exposing a manage_tmux_sessions tool to list, capture, control,
    # spawn, and kill Claude sessions running in tmux panes.
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class TmuxHandler
      include Logging
      include HandlerBase

      TOOL_NAME = "manage_tmux_sessions"
      TOOL_NAMES = [TOOL_NAME].freeze
      VALID_ACTIONS = %w[list capture status approve deny send_input spawn kill].freeze

      # Bundles spawn parameters that travel together through the confirmation and creation flow.
      SpawnRequest = Data.define(:name, :prompt, :working_dir, :session)

      # Reaction emojis and pane status labels for spawn confirmation flow.
      module Reactions
        APPROVE_EMOJIS = %w[+1 white_check_mark].freeze
        DENY_EMOJIS = %w[-1].freeze
        ALL = (APPROVE_EMOJIS + DENY_EMOJIS).freeze

        PANE_STATUS_LABELS = {
          active: "Active",
          permission: "Waiting for permission",
          idle: "Idle"
        }.freeze
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

      TARGET_REQUIRED_ACTIONS = %w[capture status approve deny send_input kill].freeze

      def call(name, arguments)
        return unless handles?(name)

        error = validate_call_args(arguments)
        return error if error

        send("handle_#{arguments["action"]}", arguments)
      end

      private

      def validate_call_args(arguments)
        action = arguments["action"]
        valid_list = VALID_ACTIONS.join(", ")
        return text_content("Error: action is required (#{valid_list})") unless action
        unless VALID_ACTIONS.include?(action)
          return text_content("Error: unknown action '#{action}'. Valid: #{valid_list}")
        end

        text_content("Error: target is required for #{action}") if target_required_but_missing?(action,
                                                                                                arguments)
      end

      def target_required_but_missing?(action, arguments)
        TARGET_REQUIRED_ACTIONS.include?(action) && !arguments["target"]
      end

      # Action handlers for list, capture, status, approve, deny, send_input, spawn, kill.
      module ActionHandlers
        private

        # --- list ---

        def handle_list(_arguments)
          return text_content("Error: tmux is not available") unless @tmux.available?

          panes = @tmux.list_all_panes
          claude_panes = select_claude_panes(panes)
          format_pane_list(panes, claude_panes)
        end

        def select_claude_panes(panes)
          panes.select { |pane| @tmux.claude_on_tty?(pane[:tty]) }
        end

        def format_pane_list(panes, claude_panes)
          return text_content("No tmux sessions running.") if panes.empty?
          return text_content("No Claude sessions found across #{panes.size} tmux panes.") if claude_panes.empty?

          lines = claude_panes.map { |pane| format_pane(pane) }
          text_content("**Claude Sessions (#{claude_panes.size}):**\n\n#{lines.join("\n")}")
        end

        # --- capture ---

        def handle_capture(arguments)
          target = arguments["target"]
          lines = arguments.fetch("lines", 100).to_i
          lines = [lines, 1].max
          output = @tmux.capture_pane(target, lines: lines)
          text_content("**`#{target}` output (last #{lines} lines):**\n```\n#{output}\n```")
        rescue Tmux::NotFound
          text_content("Error: session/pane '#{target}' not found")
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end

        # --- status ---

        def handle_status(arguments)
          target = arguments["target"]
          output = @tmux.capture_pane(target, lines: 200)
          status_label = Reactions::PANE_STATUS_LABELS.fetch(classify_pane_output(output), "Idle")
          text_content("**`#{target}` status: #{status_label}**\n```\n#{output}\n```")
        rescue Tmux::NotFound
          text_content("Error: session/pane '#{target}' not found")
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end

        # --- approve ---

        def handle_approve(arguments)
          target = arguments["target"]
          @tmux.send_keys_raw(target, "Enter")
          text_content("Approved permission on `#{target}`.")
        rescue Tmux::NotFound
          text_content("Error: session/pane '#{target}' not found")
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end

        # --- deny ---

        def handle_deny(arguments)
          target = arguments["target"]
          @tmux.send_keys_raw(target, "Escape")
          text_content("Denied permission on `#{target}`.")
        rescue Tmux::NotFound
          text_content("Error: session/pane '#{target}' not found")
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end

        # --- send_input ---

        def handle_send_input(arguments)
          target = arguments["target"]
          text = arguments["text"]
          return text_content("Error: text is required for send_input") unless text

          @tmux.send_keys(target, text)
          text_content("Sent to `#{target}`: `#{text}`")
        rescue Tmux::NotFound
          text_content("Error: session/pane '#{target}' not found")
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end

        # --- spawn ---

        def handle_spawn(arguments)
          spawn_error = validate_spawn_args(arguments)
          return spawn_error if spawn_error

          request = build_spawn_request(arguments)
          execute_spawn(request)
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end

        # --- kill ---

        def handle_kill(arguments)
          target = arguments["target"]
          kill_tmux_session(target)
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end
      end

      include ActionHandlers

      # --- helpers ---

      def text_content(text)
        { content: [{ type: "text", text: text }] }
      end

      # Pane formatting and status detection.
      module PaneOperations
        private

        def format_pane(pane)
          target, path = pane.values_at(:target, :path)
          project = File.basename(path)
          status = detect_pane_status(target)
          label = Reactions::PANE_STATUS_LABELS.fetch(status, "Idle")
          "- `#{target}` — #{project} (#{label})"
        end

        def detect_pane_status(target)
          output = @tmux.capture_pane(target, lines: 20)
          classify_pane_output(output)
        rescue Tmux::Error => error
          log(:debug, "detect_pane_status failed for #{target}: #{error.message}")
          :idle
        end

        def classify_pane_output(output)
          return :permission if output.include?("Do you want to proceed?")
          return :active if output.include?("esc to interrupt")

          :idle
        end

        def kill_tmux_session(target)
          msg = begin
            @tmux.kill_session(target)
            "Killed tmux session `#{target}`."
          rescue Tmux::NotFound
            "Error: session '#{target}' not found (cleaned up store)"
          end
          @tmux_store.delete(target)
          text_content(msg)
        end
      end

      # Spawn argument validation and request building.
      module SpawnValidation
        private

        def validate_spawn_args(arguments)
          error = validate_prompt(arguments)
          error ||= validate_working_dir(arguments)
          error || validate_session_or_name(arguments)
        end

        def validate_prompt(arguments)
          prompt = arguments["prompt"]
          text_content("Error: prompt is required for spawn") unless prompt && !prompt.strip.empty?
        end

        def validate_working_dir(arguments)
          working_dir = arguments["working_dir"]
          text_content("Error: directory '#{working_dir}' not found") if working_dir && !Dir.exist?(working_dir)
        end

        def validate_session_or_name(arguments)
          session = arguments["session"]
          if session
            validate_existing_session(session)
          else
            validate_new_session_name(arguments)
          end
        end

        def validate_existing_session(session)
          text_content("Error: session '#{session}' not found") unless @tmux.session_exists?(session)
        end

        def validate_new_session_name(arguments)
          name = arguments["name"] || generate_session_name
          if name.match?(/[.:]/)
            return text_content("Error: session name '#{name}' cannot contain '.' or ':' (tmux target delimiters)")
          end

          text_content("Error: session '#{name}' already exists") if @tmux.session_exists?(name)
        end

        def generate_session_name
          "earl-#{Time.now.strftime("%Y%m%d%H%M%S")}-#{SecureRandom.hex(2)}"
        end

        def build_spawn_request(arguments)
          name, prompt, working_dir, session = arguments.values_at("name", "prompt", "working_dir", "session")
          SpawnRequest.new(
            name: name || generate_session_name, prompt: prompt,
            working_dir: working_dir, session: session
          )
        end
      end

      # Spawn confirmation, session creation, and Mattermost messaging.
      module SpawnConfirmation
        private

        def execute_spawn(request)
          case request_spawn_confirmation(request)
          when :approved then create_spawned_session(request)
          when :error then text_content("Error: spawn confirmation failed (could not post or connect to Mattermost)")
          else text_content("Spawn denied by user.")
          end
        end

        def create_spawned_session(request)
          name, prompt, working_dir, session = request.deconstruct
          command = "claude #{Shellwords.shellescape(prompt)}"
          if session
            @tmux.create_window(session: session, name: name, command: command, working_dir: working_dir)
          else
            @tmux.create_session(name: name, command: command, working_dir: working_dir)
          end
          persist_session_info(name, working_dir, prompt)
          mode = session ? "window in `#{session}`" : "session"
          text_content("Spawned tmux #{mode} `#{name}`.\n- Prompt: #{prompt}\n- Dir: #{working_dir || Dir.pwd}")
        end

        def persist_session_info(name, working_dir, prompt)
          info = TmuxSessionStore::TmuxSessionInfo.new(
            name: name, channel_id: @config.platform_channel_id,
            thread_id: @config.platform_thread_id,
            working_dir: working_dir, prompt: prompt, created_at: Time.now.iso8601
          )
          @tmux_store.save(info)
        end

        def request_spawn_confirmation(request)
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
          log(:error, "Failed to post spawn confirmation: #{error.message}")
          nil
        end

        def build_confirmation_message(request)
          name, prompt, working_dir, session = request.deconstruct
          dir_line = working_dir ? "\n- **Dir:** #{working_dir}" : ""
          session_line = session ? "\n- **Session:** #{session} (new window)" : ""
          ":rocket: **Spawn Request**\n" \
            "Claude wants to spawn #{session ? "window" : "session"} `#{name}`\n" \
            "- **Prompt:** #{prompt}#{dir_line}#{session_line}\n" \
            "React: :+1: approve | :-1: deny"
        end

        def post_to_channel(message)
          response = @api.post("/posts", {
                                 channel_id: @config.platform_channel_id,
                                 message: message,
                                 root_id: @config.platform_thread_id
                               })

          return unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)["id"]
        end

        def add_reaction_options(post_id)
          Reactions::ALL.each do |emoji|
            response = @api.post("/reactions", {
                                   user_id: @config.platform_bot_id,
                                   post_id: post_id,
                                   emoji_name: emoji
                                 })
            log(:warn, "Failed to add reaction #{emoji} to post #{post_id}") unless response.is_a?(Net::HTTPSuccess)
          end
        rescue IOError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
          log(:error, "Failed to add reaction options to post #{post_id}: #{error.message}")
        end
      end

      # WebSocket-based polling for spawn confirmation reactions.
      module SpawnPolling
        private

        def wait_for_confirmation(post_id)
          timeout_sec = @config.permission_timeout_ms / 1000.0
          deadline = Time.now + timeout_sec

          websocket = connect_websocket
          return :error unless websocket

          poll_confirmation(websocket, post_id, deadline)
        ensure
          close_websocket(websocket)
        end

        def close_websocket(websocket)
          websocket&.close
        rescue IOError, Errno::ECONNRESET => error
          log(:debug, "Failed to close spawn confirmation WebSocket: #{error.message}")
        end

        def connect_websocket
          websocket = WebSocket::Client::Simple.connect(@config.websocket_url)
          token = @config.platform_token
          ws_ref = websocket
          websocket.on(:open) do
            ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } }))
          end
          websocket
        rescue IOError, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH => error
          log(:error, "Spawn confirmation WebSocket failed: #{error.message}")
          nil
        end

        def poll_confirmation(websocket, post_id, deadline)
          queue = setup_reaction_listener(websocket, post_id)
          await_reaction(queue, deadline)
        end

        def setup_reaction_listener(websocket, post_id)
          queue = Queue.new
          websocket.on(:message) do |msg|
            reaction_data = parse_reaction_event(msg)
            next unless reaction_data

            matches_post = reaction_data["post_id"] == post_id
            queue.push(reaction_data) if matches_post
          end
          queue
        end

        def parse_reaction_event(msg)
          raw = msg.data
          return unless raw && !raw.empty?

          parsed = JSON.parse(raw)
          event_name, nested_data = parsed.values_at("event", "data")
          return unless event_name == "reaction_added"

          reaction_json = nested_data&.dig("reaction") || "{}"
          JSON.parse(reaction_json)
        rescue JSON::ParserError
          log(:debug, "Spawn confirmation: skipped unparsable WebSocket message")
          nil
        end

        def await_reaction(queue, deadline)
          loop do
            remaining = deadline - Time.now
            return :denied if remaining <= 0

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
          return :approved if Reactions::APPROVE_EMOJIS.include?(emoji)

          :denied if Reactions::DENY_EMOJIS.include?(emoji)
        end

        def allowed_reactor?(user_id)
          allowed = @config.allowed_users
          return true if allowed.empty?

          response = @api.get("/users/#{user_id}")
          return false unless response.is_a?(Net::HTTPSuccess)

          user = JSON.parse(response.body)
          allowed.include?(user["username"])
        end

        def delete_confirmation_post(post_id)
          @api.delete("/posts/#{post_id}")
        rescue StandardError => error
          log(:warn, "Failed to delete spawn confirmation: #{error.message}")
        end
      end

      # Tool definition building: splits the large schema into composable property groups.
      module ToolDefinitionBuilder
        private

        def tool_definition
          {
            name: TOOL_NAME,
            description: tmux_tool_description,
            inputSchema: tmux_input_schema
          }
        end

        def tmux_tool_description
          "Manage Claude sessions running in tmux. " \
            "List sessions, capture output, approve/deny permissions, " \
            "send input, spawn new sessions, or kill sessions."
        end

        def tmux_input_schema
          { type: "object", properties: tmux_properties, required: %w[action] }
        end

        def tmux_properties
          {}.merge(tmux_action_properties)
            .merge(tmux_capture_properties)
            .merge(tmux_spawn_properties)
        end

        def tmux_action_properties
          {
            action: { type: "string", enum: VALID_ACTIONS, description: "Action to perform" },
            target: {
              type: "string",
              description: "Tmux pane target (e.g., 'session:window.pane'). " \
                           "Required for capture, status, approve, deny, send_input, kill."
            }
          }
        end

        def tmux_capture_properties
          {
            text: { type: "string", description: "Text to send (required for send_input)" },
            lines: { type: "integer", description: "Number of lines to capture (default 100, for capture action)" }
          }
        end

        def tmux_spawn_properties
          {
            prompt: { type: "string", description: "Prompt for new Claude session (required for spawn)" },
            name: { type: "string", description: "Session name for spawn (auto-generated if omitted)" },
            working_dir: { type: "string", description: "Working directory for spawn" },
            session: {
              type: "string",
              description: "Existing tmux session to add a window to (for spawn). " \
                           "If omitted, creates a new session."
            }
          }
        end
      end

      include PaneOperations
      include SpawnValidation
      include SpawnConfirmation
      include SpawnPolling
      include ToolDefinitionBuilder
    end
  end
end
