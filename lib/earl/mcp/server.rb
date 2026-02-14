# frozen_string_literal: true

module Earl
  module Mcp
    # Minimal JSON-RPC 2.0 server over stdio for the Claude CLI MCP integration.
    # Routes tools/list and tools/call to registered handlers via duck-typed interface:
    #   #tool_definitions → Array of tool hashes
    #   #handles?(tool_name) → Boolean
    #   #call(tool_name, arguments) → result hash
    class Server
      include Logging

      def initialize(handlers:, input: $stdin, output: $stdout)
        @handlers = Array(handlers)
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
            serverInfo: { name: "earl-mcp-server", version: "1.0.0" }
          }
        }
      end

      def tools_list_response(id)
        {
          jsonrpc: "2.0",
          id: id,
          result: {
            tools: @handlers.flat_map(&:tool_definitions)
          }
        }
      end

      def tools_call_response(id, params)
        tool_name = params&.dig("name") || params&.dig("arguments", "tool_name") || "unknown"
        arguments = params&.dig("arguments") || {}

        handler = @handlers.find { |candidate| candidate.handles?(tool_name) }
        unless handler
          return error_response(id, -32602, "No handler for tool: #{tool_name}")
        end

        log(:info, "MCP tool call: #{tool_name}")
        result = handler.call(tool_name, arguments)
        log(:info, "MCP tool result for #{tool_name}: #{result.inspect[0..200]}")

        {
          jsonrpc: "2.0",
          id: id,
          result: result
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
