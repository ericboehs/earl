# frozen_string_literal: true

module Earl
  module Mcp
    # Minimal JSON-RPC 2.0 server over stdio for the Claude CLI --permission-prompt-tool.
    # Handles initialize, notifications/initialized, tools/list, and tools/call.
    class Server
      include Logging

      TOOL_NAME = "permission_prompt"

      def initialize(handler:, input: $stdin, output: $stdout)
        @handler = handler
        @input = input
        @output = output
        @output.sync = true
      end

      def run
        @input.each_line do |line|
          request = parse_request(line)
          next unless request

          response = handle_request(request)
          write_response(response) if response
        end
      end

      private

      def parse_request(line)
        JSON.parse(line.strip)
      rescue JSON::ParserError => error
        log(:warn, "MCP: unparsable input: #{error.message}")
        nil
      end

      def handle_request(request)
        method = request["method"]
        id = request["id"]

        case method
        when "initialize"
          initialize_response(id)
        when "notifications/initialized"
          nil # notification, no response
        when "tools/list"
          tools_list_response(id)
        when "tools/call"
          tools_call_response(id, request["params"])
        else
          error_response(id, -32601, "Method not found: #{method}")
        end
      end

      def initialize_response(id)
        {
          jsonrpc: "2.0",
          id: id,
          result: {
            protocolVersion: "2024-11-05",
            capabilities: { tools: {} },
            serverInfo: { name: "earl-permission-server", version: "1.0.0" }
          }
        }
      end

      def tools_list_response(id)
        {
          jsonrpc: "2.0",
          id: id,
          result: {
            tools: [
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
          }
        }
      end

      def tools_call_response(id, params)
        tool_name = params&.dig("arguments", "tool_name") || params&.dig("tool_name") || "unknown"
        input = params&.dig("arguments", "input") || params&.dig("input") || {}

        log(:info, "MCP permission_prompt called for tool: #{tool_name}")
        result = @handler.handle(tool_name: tool_name, input: input)
        log(:info, "MCP permission result: #{result[:behavior]} for #{tool_name}")

        {
          jsonrpc: "2.0",
          id: id,
          result: {
            content: [ { type: "text", text: JSON.generate(result) } ]
          }
        }
      rescue StandardError => error
        log(:error, "MCP tool call error: #{error.class}: #{error.message}")
        log(:error, error.backtrace&.first(3)&.join("\n"))
        error_response(id, -32603, "Internal error: #{error.message}")
      end

      def error_response(id, code, message)
        {
          jsonrpc: "2.0",
          id: id,
          error: { code: code, message: message }
        }
      end

      def write_response(response)
        @output.puts(JSON.generate(response))
      end
    end
  end
end
