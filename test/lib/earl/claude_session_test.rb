require "test_helper"

class Earl::ClaudeSessionTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)
  end

  teardown do
    Earl.logger = nil
  end

  test "initializes with generated session_id" do
    session = Earl::ClaudeSession.new
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, session.session_id)
  end

  test "initializes with provided session_id" do
    session = Earl::ClaudeSession.new(session_id: "custom-id")
    assert_equal "custom-id", session.session_id
  end

  test "total_cost starts at zero" do
    session = Earl::ClaudeSession.new
    assert_equal 0.0, session.total_cost
  end

  test "stats starts with zero tokens" do
    session = Earl::ClaudeSession.new
    assert_equal 0, session.stats.total_input_tokens
    assert_equal 0, session.stats.total_output_tokens
    assert_equal 0, session.stats.turn_input_tokens
    assert_equal 0, session.stats.turn_output_tokens
  end

  test "alive? returns false before start" do
    session = Earl::ClaudeSession.new
    assert_not session.alive?
  end

  test "send_message does nothing when not alive" do
    session = Earl::ClaudeSession.new
    assert_nothing_raised { session.send_message("hello") }
  end

  test "process_pid returns nil before start" do
    session = Earl::ClaudeSession.new
    assert_nil session.process_pid
  end

  test "handle_event fires on_text for assistant events" do
    session = Earl::ClaudeSession.new
    received_text = nil
    session.on_text { |text| received_text = text }

    event = {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "text", "text" => "Hello world" }
        ]
      }
    }
    session.send(:handle_event, event)

    assert_equal "Hello world", received_text
  end

  test "handle_event concatenates multiple text content blocks" do
    session = Earl::ClaudeSession.new
    received_text = nil
    session.on_text { |text| received_text = text }

    event = {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "text", "text" => "Hello " },
          { "type" => "text", "text" => "world" }
        ]
      }
    }
    session.send(:handle_event, event)

    assert_equal "Hello world", received_text
  end

  test "handle_event fires on_tool_use for tool_use content blocks" do
    session = Earl::ClaudeSession.new
    received_tool_use = nil
    session.on_tool_use { |tu| received_tool_use = tu }

    event = {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "tool_use", "id" => "tu-1", "name" => "Bash", "input" => { "command" => "ls" } }
        ]
      }
    }
    session.send(:handle_event, event)

    assert_not_nil received_tool_use
    assert_equal "tu-1", received_tool_use[:id]
    assert_equal "Bash", received_tool_use[:name]
    assert_equal({ "command" => "ls" }, received_tool_use[:input])
  end

  test "handle_event fires on_text and on_tool_use for mixed content" do
    session = Earl::ClaudeSession.new
    received_text = nil
    received_tool_use = nil
    session.on_text { |text| received_text = text }
    session.on_tool_use { |tu| received_tool_use = tu }

    event = {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "text", "text" => "result" },
          { "type" => "tool_use", "id" => "tu-2", "name" => "Read", "input" => { "path" => "/tmp" } }
        ]
      }
    }
    session.send(:handle_event, event)

    assert_equal "result", received_text
    assert_equal "Read", received_tool_use[:name]
  end

  test "handle_event ignores non-text content blocks for on_text" do
    session = Earl::ClaudeSession.new
    received_text = nil
    session.on_text { |text| received_text = text }

    event = {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "tool_use", "id" => "tu-1", "name" => "read", "input" => {} },
          { "type" => "text", "text" => "result" }
        ]
      }
    }
    session.send(:handle_event, event)

    assert_equal "result", received_text
  end

  test "handle_event does not fire on_text for empty text" do
    session = Earl::ClaudeSession.new
    called = false
    session.on_text { |_text| called = true }

    event = {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "tool_use", "id" => "tu-1", "name" => "read", "input" => {} }
        ]
      }
    }
    session.send(:handle_event, event)

    assert_not called
  end

  test "handle_event does not fire on_text when content is not an array" do
    session = Earl::ClaudeSession.new
    called = false
    session.on_text { |_text| called = true }

    event = {
      "type" => "assistant",
      "message" => { "content" => "string" }
    }
    session.send(:handle_event, event)

    assert_not called
  end

  test "handle_event fires on_complete for result events" do
    session = Earl::ClaudeSession.new
    completed = false
    session.on_complete { |_sess| completed = true }

    event = { "type" => "result", "total_cost_usd" => 0.05, "subtype" => "success" }
    session.send(:handle_event, event)

    assert completed
  end

  test "handle_event updates total_cost from result events" do
    session = Earl::ClaudeSession.new
    session.on_complete { |_sess| }

    event = { "type" => "result", "total_cost_usd" => 0.123, "subtype" => "success" }
    session.send(:handle_event, event)

    assert_equal 0.123, session.total_cost
  end

  test "handle_event parses usage from result events" do
    session = Earl::ClaudeSession.new
    session.on_complete { |_sess| }

    event = {
      "type" => "result", "total_cost_usd" => 0.05, "subtype" => "success",
      "usage" => {
        "input_tokens" => 500,
        "output_tokens" => 200,
        "cache_read_input_tokens" => 100,
        "cache_creation_input_tokens" => 50
      }
    }
    session.send(:handle_event, event)

    assert_equal 500, session.stats.turn_input_tokens
    assert_equal 200, session.stats.turn_output_tokens
    assert_equal 100, session.stats.cache_read_tokens
    assert_equal 50, session.stats.cache_creation_tokens
  end

  test "handle_event parses modelUsage from result events" do
    session = Earl::ClaudeSession.new
    session.on_complete { |_sess| }

    event = {
      "type" => "result", "total_cost_usd" => 0.05, "subtype" => "success",
      "modelUsage" => {
        "claude-sonnet-4-20250514" => {
          "inputTokens" => 1500,
          "outputTokens" => 800,
          "contextWindow" => 200_000,
          "costUSD" => 0.05
        }
      }
    }
    session.send(:handle_event, event)

    assert_equal 1500, session.stats.total_input_tokens
    assert_equal 800, session.stats.total_output_tokens
    assert_equal 200_000, session.stats.context_window
    assert_equal "claude-sonnet-4-20250514", session.stats.model_id
  end

  test "stats context_percent calculates correctly" do
    session = Earl::ClaudeSession.new
    session.on_complete { |_sess| }

    event = {
      "type" => "result", "subtype" => "success",
      "usage" => {
        "input_tokens" => 10_000,
        "output_tokens" => 0,
        "cache_read_input_tokens" => 35_000,
        "cache_creation_input_tokens" => 5_000
      },
      "modelUsage" => {
        "claude-sonnet-4-20250514" => {
          "inputTokens" => 10_000,
          "outputTokens" => 0,
          "contextWindow" => 200_000
        }
      }
    }
    session.send(:handle_event, event)

    # context_percent = (10_000 + 35_000 + 5_000) / 200_000 * 100 = 25%
    assert_in_delta 25.0, session.stats.context_percent, 0.1
  end

  test "stats tracks time to first token" do
    session = Earl::ClaudeSession.new
    text_received = nil
    session.on_text { |text| text_received = text }

    # Simulate send_message timing
    session.stats.message_sent_at = Time.now - 1.5

    event = {
      "type" => "assistant",
      "message" => { "content" => [ { "type" => "text", "text" => "Hello" } ] }
    }
    session.send(:handle_event, event)

    assert_not_nil session.stats.first_token_at
    assert_in_delta 1.5, session.stats.time_to_first_token, 0.2
  end

  test "stats reset_turn clears per-turn data" do
    session = Earl::ClaudeSession.new
    session.stats.turn_input_tokens = 500
    session.stats.turn_output_tokens = 200
    session.stats.message_sent_at = Time.now
    session.stats.first_token_at = Time.now

    session.stats.reset_turn

    assert_equal 0, session.stats.turn_input_tokens
    assert_equal 0, session.stats.turn_output_tokens
    assert_nil session.stats.message_sent_at
    assert_nil session.stats.first_token_at
  end

  test "handle_event does not update cost when nil" do
    session = Earl::ClaudeSession.new
    session.on_complete { |_sess| }

    event = { "type" => "result", "subtype" => "success" }
    session.send(:handle_event, event)

    assert_equal 0.0, session.total_cost
  end

  test "handle_event handles system events without error" do
    session = Earl::ClaudeSession.new

    event = { "type" => "system", "subtype" => "init" }
    assert_nothing_raised { session.send(:handle_event, event) }
  end

  test "handle_event handles unknown event types" do
    session = Earl::ClaudeSession.new

    event = { "type" => "unknown" }
    assert_nothing_raised { session.send(:handle_event, event) }
  end

  test "start spawns process and creates reader threads" do
    session = Earl::ClaudeSession.new(session_id: "test-sess")

    # Create a fake 'claude' script in a temp dir
    fake_bin = File.join(scratchpad_dir, "fake_bin")
    FileUtils.mkdir_p(fake_bin)
    fake_claude = File.join(fake_bin, "claude")
    event_json = JSON.generate({ "type" => "system", "subtype" => "init" })
    File.write(fake_claude, "#!/bin/sh\necho '#{event_json}'\n")
    File.chmod(0o755, fake_claude)

    original_path = ENV["PATH"]
    ENV["PATH"] = "#{fake_bin}:#{original_path}"

    session.start
    sleep 0.3

    assert_not session.alive?
  ensure
    ENV["PATH"] = original_path if original_path
    FileUtils.rm_rf(fake_bin) if fake_bin
  end

  test "send_message writes JSON to stdin when alive" do
    session = Earl::ClaudeSession.new(session_id: "test-session")

    # Use cat as a process that stays alive and echoes back
    stdin, stdout, stderr, wait_thread = Open3.popen3("cat")
    process_state = session.instance_variable_get(:@process_state)
    process_state.stdin = stdin
    process_state.process = wait_thread

    session.send_message("Hello")
    stdin.close

    written = stdout.read
    parsed = JSON.parse(written.strip)

    assert_equal "user", parsed["type"]
    assert_equal "user", parsed.dig("message", "role")
    assert_equal "Hello", parsed.dig("message", "content")
  ensure
    [ stdin, stdout, stderr ].each { |io| io&.close rescue nil }
    wait_thread&.value rescue nil
  end

  test "kill handles already-dead process gracefully" do
    session = Earl::ClaudeSession.new

    # Spawn a process that exits immediately
    stdin, _stdout, _stderr, wait_thread = Open3.popen3("true")
    wait_thread.value # wait for it to exit

    process_state = session.instance_variable_get(:@process_state)
    process_state.process = wait_thread
    process_state.stdin = stdin

    assert_nothing_raised { session.kill }
  ensure
    [ stdin, _stdout, _stderr ].each { |io| io&.close rescue nil }
  end

  test "kill does nothing when process is nil" do
    session = Earl::ClaudeSession.new
    assert_nothing_raised { session.kill }
  end

  test "read_stdout parses JSON events" do
    session = Earl::ClaudeSession.new
    received_text = nil
    session.on_text { |text| received_text = text }

    json_line = JSON.generate({
      "type" => "assistant",
      "message" => { "content" => [ { "type" => "text", "text" => "parsed" } ] }
    })
    stdout = StringIO.new(json_line + "\n")
    session.send(:read_stdout, stdout)

    assert_equal "parsed", received_text
  end

  test "read_stdout skips invalid JSON lines" do
    session = Earl::ClaudeSession.new
    received_text = nil
    session.on_text { |text| received_text = text }

    lines = "not json\n" + JSON.generate({
      "type" => "assistant",
      "message" => { "content" => [ { "type" => "text", "text" => "valid" } ] }
    }) + "\n"
    stdout = StringIO.new(lines)
    session.send(:read_stdout, stdout)

    assert_equal "valid", received_text
  end

  test "read_stdout skips empty lines" do
    session = Earl::ClaudeSession.new
    called = false
    session.on_text { |_text| called = true }

    stdout = StringIO.new("\n\n  \n")
    session.send(:read_stdout, stdout)

    assert_not called
  end

  test "read_stderr logs lines" do
    session = Earl::ClaudeSession.new
    stderr = StringIO.new("some debug output\n")

    assert_nothing_raised { session.send(:read_stderr, stderr) }
  end

  test "kill sends multiple signals to a live process" do
    session = Earl::ClaudeSession.new

    # Use Ruby process that traps INT and loops — sleep alone gets interrupted
    stdin, stdout, stderr, wait_thread = Open3.popen3(
      "ruby", "-e", "trap('INT'){}; loop { sleep 1 rescue nil }"
    )
    sleep 0.3 # let child process start and set up trap handler
    process_state = session.instance_variable_get(:@process_state)
    process_state.process = wait_thread
    process_state.stdin = stdin

    assert wait_thread.alive?
    session.kill
    # Process may take a moment to exit after TERM
    sleep 0.2
    assert_not wait_thread.alive?
  ensure
    [ stdin, stdout, stderr ].each { |io| io&.close rescue nil }
    wait_thread&.value rescue nil
  end

  test "kill handles process that dies from first INT" do
    session = Earl::ClaudeSession.new

    # sleep doesn't trap INT so it dies from the first signal
    stdin, stdout, stderr, wait_thread = Open3.popen3("sleep", "60")
    sleep 0.2
    process_state = session.instance_variable_get(:@process_state)
    process_state.process = wait_thread
    process_state.stdin = stdin

    assert wait_thread.alive?
    session.kill
    sleep 0.1
    assert_not wait_thread.alive?
  ensure
    [ stdin, stdout, stderr ].each { |io| io&.close rescue nil }
    wait_thread&.value rescue nil
  end

  test "kill handles nil stdin and joins threads" do
    session = Earl::ClaudeSession.new

    stdin, _stdout, _stderr, wait_thread = Open3.popen3("true")
    wait_thread.value

    reader = Thread.new { }
    stderr_t = Thread.new { }
    reader.join
    stderr_t.join

    process_state = session.instance_variable_get(:@process_state)
    process_state.process = wait_thread
    # Leave stdin as nil (default) to cover &. nil branch
    process_state.reader_thread = reader
    process_state.stderr_thread = stderr_t

    assert_nothing_raised { session.kill }
  ensure
    [ stdin, _stdout, _stderr ].each { |io| io&.close rescue nil }
  end

  test "handle_event with assistant text but no on_text callback" do
    session = Earl::ClaudeSession.new

    event = {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "text", "text" => "Hello world" }
        ]
      }
    }
    assert_nothing_raised { session.send(:handle_event, event) }
  end

  test "handle_event with result but no on_complete callback" do
    session = Earl::ClaudeSession.new

    event = { "type" => "result", "total_cost_usd" => 0.05, "subtype" => "success" }
    assert_nothing_raised { session.send(:handle_event, event) }
    assert_equal 0.05, session.total_cost
  end

  # --- CLI args tests ---

  test "cli_args includes --dangerously-skip-permissions without permission_config" do
    session = Earl::ClaudeSession.new
    args = session.send(:cli_args)

    assert_includes args, "--dangerously-skip-permissions"
    assert_not_includes args, "--permission-prompt-tool"
  end

  test "cli_args includes --permission-prompt-tool with permission_config" do
    session = Earl::ClaudeSession.new(permission_config: { "PLATFORM_URL" => "http://localhost" })
    args = session.send(:cli_args)

    assert_includes args, "--permission-prompt-tool"
    assert_not_includes args, "--dangerously-skip-permissions"
  end

  test "cli_args uses --session-id by default" do
    session = Earl::ClaudeSession.new(session_id: "test-123")
    args = session.send(:cli_args)

    idx = args.index("--session-id")
    assert_not_nil idx
    assert_equal "test-123", args[idx + 1]
  end

  test "cli_args uses --resume when mode is :resume" do
    session = Earl::ClaudeSession.new(session_id: "test-123", mode: :resume)
    args = session.send(:cli_args)

    assert_includes args, "--resume"
    assert_not_includes args, "--session-id"

    idx = args.index("--resume")
    assert_equal "test-123", args[idx + 1]
  end

  test "cli_args always includes stream-json and verbose" do
    session = Earl::ClaudeSession.new
    args = session.send(:cli_args)

    assert_includes args, "--input-format"
    assert_includes args, "stream-json"
    assert_includes args, "--output-format"
    assert_includes args, "--verbose"
  end

  test "handle_event result without usage still fires on_complete" do
    session = Earl::ClaudeSession.new
    completed = false
    session.on_complete { |_sess| completed = true }

    event = { "type" => "result", "subtype" => "success" }
    session.send(:handle_event, event)

    assert completed
    assert_equal 0, session.stats.turn_input_tokens
  end

  test "handle_event result with nil modelUsage is handled" do
    session = Earl::ClaudeSession.new
    session.on_complete { |_sess| }

    event = { "type" => "result", "subtype" => "success", "modelUsage" => nil }
    session.send(:handle_event, event)

    assert_equal 0, session.stats.total_input_tokens
  end

  test "stats tokens_per_second returns nil without timing" do
    session = Earl::ClaudeSession.new
    assert_nil session.stats.tokens_per_second
  end

  test "stats tokens_per_second calculates correctly" do
    session = Earl::ClaudeSession.new
    session.stats.first_token_at = Time.now - 2.0
    session.stats.complete_at = Time.now
    session.stats.turn_output_tokens = 100

    assert_in_delta 50.0, session.stats.tokens_per_second, 5.0
  end

  test "stats tokens_per_second returns nil with zero output tokens" do
    session = Earl::ClaudeSession.new
    session.stats.first_token_at = Time.now - 1.0
    session.stats.complete_at = Time.now
    session.stats.turn_output_tokens = 0

    assert_nil session.stats.tokens_per_second
  end

  test "stats context_percent returns nil without context_window" do
    session = Earl::ClaudeSession.new
    assert_nil session.stats.context_percent
  end

  test "stats time_to_first_token returns nil without timing" do
    session = Earl::ClaudeSession.new
    assert_nil session.stats.time_to_first_token
  end

  test "send_message resets turn stats when alive" do
    session = Earl::ClaudeSession.new(session_id: "test-session")
    session.stats.turn_input_tokens = 500
    session.stats.turn_output_tokens = 200
    session.stats.first_token_at = Time.now

    # Use cat as a process that stays alive
    stdin, stdout, stderr, wait_thread = Open3.popen3("cat")
    process_state = session.instance_variable_get(:@process_state)
    process_state.stdin = stdin
    process_state.process = wait_thread

    session.send_message("test")

    assert_equal 0, session.stats.turn_input_tokens
    assert_equal 0, session.stats.turn_output_tokens
    assert_nil session.stats.first_token_at
    assert_not_nil session.stats.message_sent_at
  ensure
    [ stdin, stdout, stderr ].each { |io| io&.close rescue nil }
    wait_thread&.value rescue nil
  end

  test "format_result_log includes all available stats" do
    session = Earl::ClaudeSession.new
    session.on_complete { |_sess| }

    event = {
      "type" => "result", "total_cost_usd" => 0.05, "subtype" => "success",
      "usage" => { "input_tokens" => 500, "output_tokens" => 200 },
      "modelUsage" => {
        "claude-sonnet-4-20250514" => {
          "inputTokens" => 1500, "outputTokens" => 800,
          "contextWindow" => 200_000
        }
      }
    }
    session.stats.message_sent_at = Time.now - 2.0
    session.send(:handle_event, event)

    log = session.send(:format_result_log)
    assert_includes log, "2300 total tokens"
    assert_includes log, "in:500"
    assert_includes log, "out:200"
    assert_includes log, "context used"
    assert_includes log, "cost=$0.0500"
    assert_includes log, "claude-sonnet-4-20250514"
  end

  private

  def scratchpad_dir
    dir = File.join(Dir.tmpdir, "earl-tests")
    FileUtils.mkdir_p(dir)
    dir
  end
end
