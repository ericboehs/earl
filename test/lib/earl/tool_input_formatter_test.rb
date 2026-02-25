# frozen_string_literal: true

require "test_helper"

module Earl
  class ToolInputFormatterTest < Minitest::Test
    setup do
      @formatter = Object.new
      @formatter.extend(Earl::ToolInputFormatter)
    end

    test "format_tool_display with known tool and detail" do
      result = @formatter.format_tool_display("Bash", { "command" => "echo hi" })
      assert_includes result, "🔧 `Bash`"
      assert_includes result, "echo hi"
    end

    test "format_tool_display with known tool and nil input returns icon only" do
      result = @formatter.format_tool_display("Bash", nil)
      assert_equal "🔧 `Bash`", result
    end

    test "format_tool_display with unknown tool and nil input returns icon only" do
      result = @formatter.format_tool_display("CustomTool", nil)
      assert_equal "⚙️ `CustomTool`", result
    end

    test "format_tool_display with unknown tool and empty input returns icon only" do
      result = @formatter.format_tool_display("CustomTool", {})
      assert_equal "⚙️ `CustomTool`", result
    end

    test "format_tool_display with unknown tool and populated input shows JSON" do
      result = @formatter.format_tool_display("CustomTool", { "key" => "value" })
      assert_includes result, "⚙️ `CustomTool`"
      assert_includes result, '"key"'
      assert_includes result, '"value"'
    end

    test "extract_tool_detail_from returns nil for known tool with nil input" do
      result = @formatter.send(:extract_tool_detail_from, "Read", nil)
      assert_nil result
    end

    test "summarize_input returns nil for nil" do
      assert_nil @formatter.send(:summarize_input, nil)
    end

    test "summarize_input returns nil for empty hash" do
      assert_nil @formatter.send(:summarize_input, {})
    end

    test "summarize_input returns JSON for populated hash" do
      result = @formatter.send(:summarize_input, { "foo" => "bar" })
      assert_includes result, "foo"
    end
  end
end
