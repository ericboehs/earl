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

    request = { jsonrpc: "2.0", id: 1, method: "initialize", params: {} }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 1, response["id"]
    assert_equal "2024-11-05", response.dig("result", "protocolVersion")
    assert_equal "earl-mcp-server", response.dig("result", "serverInfo", "name")
  end

  test "handles notifications/initialized without response" do
    output = StringIO.new
    handler = mock_handler

    request = { jsonrpc: "2.0", method: "notifications/initialized" }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    assert_equal "", output.string
  end

  test "handles tools/list request with single handler" do
    output = StringIO.new
    handler = mock_handler

    request = { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 2, response["id"]

    tools = response.dig("result", "tools")
    assert_equal 1, tools.size
    assert_equal "permission_prompt", tools.first["name"]
  end

  test "handles tools/list aggregates tools from multiple handlers" do
    output = StringIO.new
    handler1 = mock_handler
    handler2 = mock_handler(tool_name: "save_memory", description: "Save a memory")

    request = { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler1, handler2 ], input: input, output: output)
    server.run

    response = parse_output(output)
    tools = response.dig("result", "tools")
    assert_equal 2, tools.size
    names = tools.map { |t| t["name"] }
    assert_includes names, "permission_prompt"
    assert_includes names, "save_memory"
  end

  test "handles tools/call request and delegates to correct handler" do
    output = StringIO.new
    handler = mock_handler(call_result: { content: [ { type: "text", text: '{"behavior":"allow"}' } ] })

    request = {
      jsonrpc: "2.0", id: 3, method: "tools/call",
      params: { name: "permission_prompt", arguments: { tool_name: "Bash", input: { command: "ls" } } }
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 3, response["id"]

    content = response.dig("result", "content")
    assert_equal 1, content.size
    assert_equal "text", content.first["type"]

    result = JSON.parse(content.first["text"])
    assert_equal "allow", result["behavior"]
  end

  test "handles tools/call falls back to arguments.tool_name for legacy format" do
    output = StringIO.new
    handler = mock_handler(call_result: { content: [ { type: "text", text: '{"ok":true}' } ] })

    request = {
      jsonrpc: "2.0", id: 3, method: "tools/call",
      params: { arguments: { tool_name: "permission_prompt", input: {} } }
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    # Should not be an error — the handler should have been found
    assert_nil response["error"]
  end

  test "returns error when no handler matches tool" do
    output = StringIO.new
    handler = mock_handler

    request = {
      jsonrpc: "2.0", id: 3, method: "tools/call",
      params: { name: "unknown_tool", arguments: {} }
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal(-32602, response.dig("error", "code"))
    assert_includes response.dig("error", "message"), "unknown_tool"
  end

  test "returns error for unknown method" do
    output = StringIO.new
    handler = mock_handler

    request = { jsonrpc: "2.0", id: 4, method: "unknown/method", params: {} }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 4, response["id"]
    assert_equal(-32601, response.dig("error", "code"))
  end

  test "skips unparsable JSON lines" do
    output = StringIO.new
    handler = mock_handler

    input = StringIO.new("not json{{\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)

    assert_nothing_raised { server.run }
    assert_equal "", output.string
  end

  test "handles handler error gracefully" do
    output = StringIO.new
    handler = mock_handler(call_raises: "boom")

    request = {
      jsonrpc: "2.0", id: 5, method: "tools/call",
      params: { name: "permission_prompt", arguments: { tool_name: "Bash", input: { command: "ls" } } }
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 5, response["id"]
    assert_equal(-32603, response.dig("error", "code"))
    assert_includes response.dig("error", "message"), "boom"
  end

  test "routes to correct handler among multiple" do
    output = StringIO.new
    handler1 = mock_handler(tool_name: "permission_prompt",
                            call_result: { content: [ { type: "text", text: "from_handler1" } ] })
    handler2 = mock_handler(tool_name: "save_memory",
                            call_result: { content: [ { type: "text", text: "from_handler2" } ] })

    request = {
      jsonrpc: "2.0", id: 6, method: "tools/call",
      params: { name: "save_memory", arguments: { text: "remember this" } }
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler1, handler2 ], input: input, output: output)
    server.run

    response = parse_output(output)
    assert_equal 6, response["id"]
    content = response.dig("result", "content")
    assert_equal "from_handler2", content.first["text"]
  end

  test "handles tools/call with nil params.name falls through to arguments.tool_name" do
    output = StringIO.new
    handler = mock_handler(call_result: { content: [ { type: "text", text: "ok" } ] })

    request = {
      jsonrpc: "2.0", id: 7, method: "tools/call",
      params: { arguments: { tool_name: "permission_prompt" } }
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    assert_nil response["error"]
  end

  test "handles tools/call with nil arguments defaults to empty hash" do
    output = StringIO.new
    handler = mock_handler(tool_name: "unknown",
                           call_result: { content: [ { type: "text", text: "ok" } ] })

    request = {
      jsonrpc: "2.0", id: 8, method: "tools/call",
      params: { name: "unknown" }
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    assert_nil response["error"]
  end

  test "handles tools/call with completely nil params returns no handler error" do
    output = StringIO.new
    handler = mock_handler

    request = {
      jsonrpc: "2.0", id: 9, method: "tools/call",
      params: nil
    }
    input = StringIO.new(JSON.generate(request) + "\n")
    server = Earl::Mcp::Server.new(handlers: [ handler ], input: input, output: output)
    server.run

    response = parse_output(output)
    # nil params results in tool_name "unknown" which no handler matches
    assert_equal(-32602, response.dig("error", "code"))
  end

  private

  def mock_handler(tool_name: "permission_prompt", description: "Request permission",
                   call_result: nil, call_raises: nil)
    tn = tool_name
    desc = description
    cr = call_result || { content: [ { type: "text", text: '{"behavior":"allow"}' } ] }
    err = call_raises

    handler = Object.new
    handler.define_singleton_method(:tool_definitions) do
      [ { name: tn, description: desc, inputSchema: { type: "object", properties: {} } } ]
    end
    handler.define_singleton_method(:handles?) { |name| name == tn }
    handler.define_singleton_method(:call) do |_name, _args|
      raise err if err

      cr
    end
    handler
  end

  def parse_output(output)
    JSON.parse(output.string.strip.split("\n").last)
  end
end
