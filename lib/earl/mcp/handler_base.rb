# frozen_string_literal: true

module Earl
  module Mcp
    # Shared handler interface for MCP tool routing. Including classes define
    # a TOOL_NAMES constant; `handles?` checks membership against it.
    module HandlerBase
      def handles?(name)
        self.class::TOOL_NAMES.include?(name)
      end
    end
  end
end
