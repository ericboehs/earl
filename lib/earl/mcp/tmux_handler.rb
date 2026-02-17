# frozen_string_literal: true

require "shellwords"

module Earl
  module Mcp
    # MCP handler exposing a manage_tmux_sessions tool to list, capture, control,
    # spawn, and kill Claude sessions running in tmux panes.
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class TmuxHandler
      include Logging

      TOOL_NAME = "manage_tmux_sessions"
      VALID_ACTIONS = %w[list capture status approve deny send_input spawn kill].freeze

      APPROVE_EMOJIS = %w[+1 white_check_mark].freeze
      DENY_EMOJIS = %w[-1].freeze
      REACTION_EMOJIS = %w[+1 white_check_mark -1].freeze

      PANE_STATUS_LABELS = {
        active: "Active",
        permission: "Waiting for permission",
        idle: "Idle"
      }.freeze

      def initialize(config:, api_client:, tmux_store:, tmux_adapter: Tmux)
        @config = config
        @api = api_client
        @tmux_store = tmux_store
        @tmux = tmux_adapter
      end

      def tool_definitions
        [ tool_definition ]
      end

      def handles?(name)
        name == TOOL_NAME
      end

      def call(name, arguments)
        return unless name == TOOL_NAME

        action = arguments["action"]
        return text_content("Error: action is required (#{VALID_ACTIONS.join(', ')})") unless action
        return text_content("Error: unknown action '#{action}'. Valid: #{VALID_ACTIONS.join(', ')}") unless VALID_ACTIONS.include?(action)

        send("handle_#{action}", arguments)
      end

      private

      # --- list ---

      def handle_list(_arguments)
        return text_content("Error: tmux is not available") unless @tmux.available?

        panes = @tmux.list_all_panes
        return text_content("No tmux sessions running.") if panes.empty?

        claude_panes = panes.select { |pane| @tmux.claude_on_tty?(pane[:tty]) }
        return text_content("No Claude sessions found across #{panes.size} tmux panes.") if claude_panes.empty?

        lines = claude_panes.map { |pane| format_pane(pane) }
        text_content("**Claude Sessions (#{claude_panes.size}):**\n\n#{lines.join("\n")}")
      end

      def format_pane(pane)
        target = pane[:target]
        project = File.basename(pane[:path])
        status = detect_pane_status(target)
        "- `#{target}` — #{project} (#{PANE_STATUS_LABELS.fetch(status, 'Idle')})"
      end

      def detect_pane_status(target)
        output = @tmux.capture_pane(target, lines: 20)
        return :permission if output.include?("Do you want to proceed?")
        return :active if output.include?("esc to interrupt")

        :idle
      rescue Tmux::Error
        :idle
      end

      # --- capture ---

      def handle_capture(arguments)
        target = arguments["target"]
        return text_content("Error: target is required for capture") unless target

        lines = arguments.fetch("lines", 100).to_i
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
        return text_content("Error: target is required for status") unless target

        output = @tmux.capture_pane(target, lines: 200)
        status_label = PANE_STATUS_LABELS.fetch(detect_pane_status(target), "Idle")
        text_content("**`#{target}` status: #{status_label}**\n```\n#{output}\n```")
      rescue Tmux::NotFound
        text_content("Error: session/pane '#{target}' not found")
      rescue Tmux::Error => error
        text_content("Error: #{error.message}")
      end
      # --- approve ---

      def handle_approve(arguments)
        target = arguments["target"]
        return text_content("Error: target is required for approve") unless target

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
        return text_content("Error: target is required for deny") unless target

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
        return text_content("Error: target is required for send_input") unless target

        text = arguments["text"]
        return text_content("Error: text is required for send_input") unless text

        @tmux.send_keys(target, text)
        text_content("Sent to `#{target}`: `#{text}`")
      rescue Tmux::Error => error
        text_content("Error: #{error.message}")
      end
      # --- spawn ---

      def handle_spawn(arguments)
        prompt = arguments["prompt"]
        return text_content("Error: prompt is required for spawn") unless prompt && !prompt.strip.empty?

        name = arguments["name"] || "earl-#{Time.now.strftime('%Y%m%d%H%M%S')}"
        return text_content("Error: name '#{name}' cannot contain '.' or ':' (tmux reserved)") if name.match?(/[.:]/)

        working_dir = arguments["working_dir"]
        return text_content("Error: directory '#{working_dir}' not found") if working_dir && !Dir.exist?(working_dir)
        return text_content("Error: session '#{name}' already exists") if @tmux.session_exists?(name)

        approved = request_spawn_confirmation(name: name, prompt: prompt, working_dir: working_dir)
        return text_content("Spawn denied by user.") unless approved

        create_spawned_session(name: name, prompt: prompt, working_dir: working_dir)
      rescue Tmux::Error => error
        text_content("Error: #{error.message}")
      end

      # --- kill ---

      def handle_kill(arguments)
        target = arguments["target"]
        return text_content("Error: target is required for kill") unless target

        kill_tmux_session(target)
      rescue Tmux::Error => error
        text_content("Error: #{error.message}")
      end

      def kill_tmux_session(target)
        @tmux.kill_session(target)
        @tmux_store.delete(target)
        text_content("Killed tmux session `#{target}`.")
      rescue Tmux::NotFound
        @tmux_store.delete(target)
        text_content("Error: session '#{target}' not found (cleaned up store)")
      end

      # --- spawn helpers ---

      def create_spawned_session(name:, prompt:, working_dir:)
        command = "claude #{Shellwords.shellescape(prompt)}"
        @tmux.create_session(name: name, command: command, working_dir: working_dir)

        info = TmuxSessionStore::TmuxSessionInfo.new(
          name: name, channel_id: @config.platform_channel_id,
          thread_id: @config.platform_thread_id,
          working_dir: working_dir, prompt: prompt, created_at: Time.now.iso8601
        )
        @tmux_store.save(info)

        text_content("Spawned tmux session `#{name}`.\n- Prompt: #{prompt}\n- Dir: #{working_dir || Dir.pwd}")
      end

      def request_spawn_confirmation(name:, prompt:, working_dir:)
        post_id = post_confirmation_request(name, prompt, working_dir)
        return false unless post_id

        add_reaction_options(post_id)
        result = wait_for_confirmation(post_id)
        delete_confirmation_post(post_id)
        result
      end

      def post_confirmation_request(name, prompt, working_dir)
        dir_line = working_dir ? "\n- **Dir:** #{working_dir}" : ""
        message = ":rocket: **Spawn Request**\n" \
                  "Claude wants to spawn session `#{name}`\n" \
                  "- **Prompt:** #{prompt}#{dir_line}\n" \
                  "React: :+1: approve | :-1: deny"

        response = @api.post("/posts", {
          channel_id: @config.platform_channel_id,
          message: message,
          root_id: @config.platform_thread_id
        })

        return unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)["id"]
      rescue StandardError => error
        log(:error, "Failed to post spawn confirmation: #{error.message}")
        nil
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

      def wait_for_confirmation(post_id)
        timeout_sec = @config.permission_timeout_ms / 1000.0
        deadline = Time.now + timeout_sec

        ws = connect_websocket
        return false unless ws

        result = poll_confirmation(ws, post_id, deadline)
        result == true
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
        log(:error, "Spawn confirmation WebSocket failed: #{error.message}")
        nil
      end

      def poll_confirmation(ws, post_id, deadline)
        reaction_queue = Queue.new

        ws.on(:message) do |msg|
          next unless msg.data && !msg.data.empty?

          begin
            event = JSON.parse(msg.data)
            if event["event"] == "reaction_added"
              reaction_data = JSON.parse(event.dig("data", "reaction") || "{}")
              reaction_queue.push(reaction_data) if reaction_data["post_id"] == post_id
            end
          rescue JSON::ParserError
            nil
          end
        end

        loop do
          remaining = deadline - Time.now
          return false if remaining <= 0

          reaction = begin
            reaction_queue.pop(true)
          rescue ThreadError
            sleep 0.5
            nil
          end

          next unless reaction
          next if reaction["user_id"] == @config.platform_bot_id

          return true if APPROVE_EMOJIS.include?(reaction["emoji_name"])
          return false if DENY_EMOJIS.include?(reaction["emoji_name"])
        end
      end

      def delete_confirmation_post(post_id)
        @api.delete("/posts/#{post_id}")
      rescue StandardError => error
        log(:warn, "Failed to delete spawn confirmation: #{error.message}")
      end

      # --- helpers ---

      def text_content(text)
        { content: [ { type: "text", text: text } ] }
      end

      def tool_definition
        {
          name: TOOL_NAME,
          description: "Manage Claude sessions running in tmux. " \
                       "List sessions, capture output, approve/deny permissions, send input, spawn new sessions, or kill sessions.",
          inputSchema: {
            type: "object",
            properties: {
              action: {
                type: "string",
                enum: VALID_ACTIONS,
                description: "Action to perform"
              },
              target: {
                type: "string",
                description: "Tmux pane target (e.g., 'session:window.pane'). Required for capture, status, approve, deny, send_input, kill."
              },
              text: {
                type: "string",
                description: "Text to send (required for send_input)"
              },
              lines: {
                type: "integer",
                description: "Number of lines to capture (default 100, for capture action)"
              },
              prompt: {
                type: "string",
                description: "Prompt for new Claude session (required for spawn)"
              },
              name: {
                type: "string",
                description: "Session name for spawn (auto-generated if omitted)"
              },
              working_dir: {
                type: "string",
                description: "Working directory for spawn"
              }
            },
            required: %w[action]
          }
        }
      end
    end
  end
end
