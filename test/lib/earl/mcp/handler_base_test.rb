# frozen_string_literal: true

require "test_helper"

module Earl
  module Mcp
    class HandlerBaseTest < Minitest::Test
      # Minimal test class including HandlerBase
      class TestHandler
        include Earl::Mcp::HandlerBase

        TOOL_NAMES = %w[tool_a tool_b].freeze
      end

      test "handles? returns true for tool names in TOOL_NAMES" do
        handler = TestHandler.new
        assert handler.handles?("tool_a")
        assert handler.handles?("tool_b")
      end

      test "handles? returns false for unknown tool names" do
        handler = TestHandler.new
        assert_not handler.handles?("tool_c")
        assert_not handler.handles?("")
      end

      test "handles? works with MemoryHandler" do
        store = Object.new
        store.define_singleton_method(:save) { |**_| {} }
        store.define_singleton_method(:search) { |**_| [] }

        handler = Earl::Mcp::MemoryHandler.new(store: store)
        assert handler.handles?("save_memory")
        assert handler.handles?("search_memory")
        assert_not handler.handles?("unknown_tool")
      end
    end
  end
end
