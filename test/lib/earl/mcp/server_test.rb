require "test_helper"

class Earl::Mcp::ServerTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)
  end

  teardown do
    Earl.logger = nil
  end

  test "handles initialize request" do
    output = StringIO.new
    handler = mock_handler
    server = Earl::Mcp::Server.new(handler: handler, input: StringIO.new, output: output)

    request = { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handler: handler, input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 1, response["id"]
    assert_equal "2024-11-05", response.dig("result", "protocolVersion")
    assert_equal "earl-permission-server", response.dig("result", "serverInfo", "name")
  end

  test "handles notifications/initialized without response" do
    output = StringIO.new
    handler = mock_handler

    request = { jsonrpc: "2.0", method: "notifications/initialized" }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handler: handler, input: input, output: output)
    server.run

    assert_equal "", output.string
  end

  test "handles tools/list request" do
    output = StringIO.new
    handler = mock_handler

    request = { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handler: handler, input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 2, response["id"]

    tools = response.dig("result", "tools")
    assert_equal 1, tools.size
    assert_equal "permission_prompt", tools.first["name"]
  end

  test "handles tools/call request and delegates to handler" do
    output = StringIO.new
    handler = mock_handler(result: { behavior: "allow", updatedInput: nil })

    request = {
      jsonrpc: "2.0", id: 3, method: "tools/call",
      params: { arguments: { tool_name: "Bash", input: { command: "ls" } } }
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handler: handler, input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 3, response["id"]

    content = response.dig("result", "content")
    assert_equal 1, content.size
    assert_equal "text", content.first["type"]

    result = JSON.parse(content.first["text"])
    assert_equal "allow", result["behavior"]
  end

  test "returns error for unknown method" do
    output = StringIO.new
    handler = mock_handler

    request = { jsonrpc: "2.0", id: 4, method: "unknown/method", params: {} }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handler: handler, input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 4, response["id"]
    assert_equal(-32601, response.dig("error", "code"))
  end

  test "skips unparsable JSON lines" do
    output = StringIO.new
    handler = mock_handler

    input = StringIO.new("not json{{\n")
    server = Earl::Mcp::Server.new(handler: handler, input: input, output: output)

    assert_nothing_raised { server.run }
    assert_equal "", output.string
  end

  test "handles handler error gracefully" do
    output = StringIO.new
    handler = Object.new
    handler.define_singleton_method(:handle) { |**_kwargs| raise "boom" }

    request = {
      jsonrpc: "2.0", id: 5, method: "tools/call",
      params: { arguments: { tool_name: "Bash", input: { command: "ls" } } }
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handler: handler, input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 5, response["id"]
    assert_equal(-32603, response.dig("error", "code"))
    assert_includes response.dig("error", "message"), "boom"
  end

  private

  def mock_handler(result: { behavior: "allow", updatedInput: nil })
    handler = Object.new
    handler.define_singleton_method(:handle) { |**_kwargs| result }
    handler
  end

  def parse_output(output)
    JSON.parse(output.string.strip.split("\n").last)
  end
end
