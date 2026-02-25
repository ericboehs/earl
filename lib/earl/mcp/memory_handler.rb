# frozen_string_literal: true

module Earl
  module Mcp
    # MCP handler exposing save_memory and search_memory tools.
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class MemoryHandler
      include HandlerBase

      TOOL_NAMES = %w[save_memory search_memory].freeze

      def initialize(store:, username: nil)
        @store = store
        @username = username
      end

      def tool_definitions
        [save_memory_definition, search_memory_definition]
      end

      DISPATCH = { "save_memory" => :handle_save, "search_memory" => :handle_search }.freeze

      def call(name, arguments)
        method = DISPATCH[name]
        return unless method

        send(method, arguments)
      end

      private

      def handle_save(arguments)
        text = arguments["text"] || arguments["fact"] || ""
        username = arguments["username"] || @username || "unknown"

        result = @store.save(username: username, text: text)
        text_content("Saved: #{result[:entry]}")
      end

      def handle_search(arguments)
        query = arguments["query"] || ""
        limit = (arguments["limit"] || 20).to_i

        results = @store.search(query: query, limit: limit)
        return text_content("No memories found for: #{query}") if results.empty?

        text_content(format_search_results(results))
      end

      def format_search_results(results)
        count = results.size
        formatted = results.map { |result| "**#{result[:file]}**: #{result[:line]}" }.join("\n")
        "Found #{count} memor#{count == 1 ? "y" : "ies"}:\n#{formatted}"
      end

      def text_content(text)
        { content: [{ type: "text", text: text }] }
      end

      def save_memory_definition
        build_tool_definition(
          "save_memory",
          "Save a fact or observation to persistent memory. " \
          "Use this to remember important information about users, preferences, or context.",
          text: { type: "string", description: "The fact or observation to save" },
          username: { type: "string", description: "The username this memory relates to (optional)" }
        )
      end

      def search_memory_definition
        build_tool_definition(
          "search_memory",
          "Search persistent memory for previously saved facts. " \
          "Use this to recall information about users, preferences, or past interactions.",
          query: { type: "string", description: "Keywords to search for" },
          limit: { type: "integer", description: "Maximum results to return (default: 20)" }
        )
      end

      def build_tool_definition(name, description, **properties)
        required = name == "save_memory" ? %w[text] : %w[query]
        {
          name: name, description: description,
          inputSchema: { type: "object", properties: properties, required: required }
        }
      end
    end
  end
end
