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
        method_name, request_id, params = request.values_at("method", "id", "params")
        dispatch_method(method_name, request_id, params || {})
      end

      def dispatch_method(method_name, request_id, params)
        case method_name
        when "initialize" then initialize_response(request_id)
        when "notifications/initialized" then nil
        when "tools/list" then tools_list_response(request_id)
        when "tools/call" then tools_call_response(request_id, params)
        else error_response(request_id, -32_601, "Method not found: #{method_name}")
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
        tool_name, arguments = extract_tool_params(params)
        handler = find_tool_handler(tool_name)
        return error_response(id, -32_602, "No handler for tool: #{tool_name}") unless handler

        log(:info, "MCP tool call: #{tool_name}")
        result = handler.call(tool_name, arguments)
        log_tool_result(tool_name, result)

        { jsonrpc: "2.0", id: id, result: result }
      rescue StandardError => error
        handle_tool_error(id, error)
      end

      def extract_tool_params(args)
        tool_name = args["name"] || args.dig("arguments", "tool_name") || "unknown"
        [tool_name, args["arguments"] || {}]
      end

      def find_tool_handler(tool_name)
        @handlers.find { |candidate| candidate.handles?(tool_name) }
      end

      def log_tool_result(tool_name, result)
        log(:info, "MCP tool result for #{tool_name}: #{result.inspect[0..200]}")
      end

      def handle_tool_error(id, error)
        msg = error.message
        log(:error, "MCP tool call error: #{error.class}: #{msg}")
        log(:error, error.backtrace&.first(3)&.join("\n"))
        error_response(id, -32_603, "Internal error: #{msg}")
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
