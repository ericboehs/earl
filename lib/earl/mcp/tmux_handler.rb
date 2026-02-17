# frozen_string_literal: true

module Earl
  module Mcp
    # MCP handler exposing a manage_tmux_sessions tool to list, capture, control,
    # spawn, and kill Claude sessions running in tmux panes.
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class TmuxHandler
      include Logging

      TOOL_NAME = "manage_tmux_sessions"
      VALID_ACTIONS = %w[list capture status approve deny send_input spawn kill].freeze

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

      # Placeholder stubs for remaining actions (implemented in later tasks)
      def handle_capture(_arguments) = text_content("Not yet implemented")
      def handle_status(_arguments) = text_content("Not yet implemented")
      def handle_approve(_arguments) = text_content("Not yet implemented")
      def handle_deny(_arguments) = text_content("Not yet implemented")
      def handle_send_input(_arguments) = text_content("Not yet implemented")
      def handle_spawn(_arguments) = text_content("Not yet implemented")
      def handle_kill(_arguments) = text_content("Not yet implemented")

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
