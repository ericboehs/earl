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

  test "alive? returns false before start" do
    session = Earl::ClaudeSession.new
    assert_not session.alive?
  end

  test "send_message does nothing when not alive" do
    session = Earl::ClaudeSession.new
    assert_nothing_raised { session.send_message("hello") }
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

  test "handle_event ignores non-text content blocks" do
    session = Earl::ClaudeSession.new
    received_text = nil
    session.on_text { |text| received_text = text }

    event = {
      "type" => "assistant",
      "message" => {
        "content" => [
          { "type" => "tool_use", "name" => "read" },
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
          { "type" => "tool_use", "name" => "read" }
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
    session.instance_variable_set(:@stdin, stdin)
    session.instance_variable_set(:@process, wait_thread)

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

    session.instance_variable_set(:@process, wait_thread)
    session.instance_variable_set(:@stdin, stdin)

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
    session.instance_variable_set(:@process, wait_thread)
    session.instance_variable_set(:@stdin, stdin)

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
    session.instance_variable_set(:@process, wait_thread)
    session.instance_variable_set(:@stdin, stdin)

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

    session.instance_variable_set(:@process, wait_thread)
    # Leave @stdin as nil (default) to cover &. nil branch
    session.instance_variable_set(:@reader_thread, reader)
    session.instance_variable_set(:@stderr_thread, stderr_t)

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

  private

  def scratchpad_dir
    dir = "/private/tmp/claude-501/earl-tests"
    FileUtils.mkdir_p(dir)
    dir
  end
end
