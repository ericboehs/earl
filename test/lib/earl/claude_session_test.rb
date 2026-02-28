# frozen_string_literal: true

require "test_helper"

module Earl
  class ClaudeSessionTest < Minitest::Test
    setup do
      Earl.logger = Logger.new(File::NULL)
    end

    teardown do
      Earl.logger = nil
    end

    def stub_mcp_config(env: { "PLATFORM_URL" => "http://localhost" }, skip_permissions: false)
      Earl::ClaudeSession::McpConfig.new(env: env, skip_permissions: skip_permissions)
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
      assert_equal 0.0, session.stats.total_cost
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

    test "send_message returns false when not alive" do
      session = Earl::ClaudeSession.new
      assert_equal false, session.send_message("hello")
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

      assert_equal 0.123, session.stats.total_cost
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
      session.on_text { |_text| }

      # Simulate send_message timing
      session.stats.message_sent_at = Time.now - 1.5

      event = {
        "type" => "assistant",
        "message" => { "content" => [{ "type" => "text", "text" => "Hello" }] }
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

      assert_equal 0.0, session.stats.total_cost
    end

    test "handle_event handles system events without error" do
      session = Earl::ClaudeSession.new

      event = { "type" => "system", "subtype" => "init" }
      assert_nothing_raised { session.send(:handle_event, event) }
    end

    test "handle_system_event with message fires on_system callback" do
      session = Earl::ClaudeSession.new
      received = nil
      session.on_system { |event| received = event }

      event = { "type" => "system", "subtype" => "init", "message" => "Initializing..." }
      session.send(:handle_event, event)

      assert_not_nil received
      assert_equal "init", received[:subtype]
      assert_equal "Initializing...", received[:message]
    end

    test "handle_system_event without message does not fire on_system" do
      session = Earl::ClaudeSession.new
      called = false
      session.on_system { |_event| called = true }

      event = { "type" => "system", "subtype" => "init" }
      session.send(:handle_event, event)

      assert_not called
    end

    test "handle_system_event with message but no callback does not raise" do
      session = Earl::ClaudeSession.new

      event = { "type" => "system", "subtype" => "init", "message" => "test" }
      assert_nothing_raised { session.send(:handle_event, event) }
    end

    test "model_args returns model flag when EARL_MODEL is set" do
      original = ENV.fetch("EARL_MODEL", nil)
      ENV["EARL_MODEL"] = "claude-opus-4-20250514"

      session = Earl::ClaudeSession.new
      args = session.send(:model_args)

      assert_equal ["--model", "claude-opus-4-20250514"], args
    ensure
      if original
        ENV["EARL_MODEL"] = original
      else
        ENV.delete("EARL_MODEL")
      end
    end

    test "model_args returns empty when EARL_MODEL is not set" do
      original = ENV.fetch("EARL_MODEL", nil)
      ENV.delete("EARL_MODEL")

      session = Earl::ClaudeSession.new
      args = session.send(:model_args)

      assert_empty args
    ensure
      ENV["EARL_MODEL"] = original if original
    end

    test "handle_event handles unknown event types" do
      session = Earl::ClaudeSession.new

      event = { "type" => "unknown" }
      assert_nothing_raised { session.send(:handle_event, event) }
    end

    test "start spawns process and creates reader threads" do
      fake_bin = File.join(scratchpad_dir, "fake_bin")
      FileUtils.mkdir_p(fake_bin)
      session = Earl::ClaudeSession.new(session_id: "test-sess", working_dir: fake_bin)

      # Create a fake 'claude' script in a temp dir
      fake_claude = File.join(fake_bin, "claude")
      event_json = JSON.generate({ "type" => "system", "subtype" => "init" })
      File.write(fake_claude, "#!/bin/sh\necho '#{event_json}'\n")
      File.chmod(0o755, fake_claude)

      original_path = ENV.fetch("PATH", nil)
      ENV["PATH"] = "#{fake_bin}:#{original_path}"

      session.start
      sleep 0.5

      assert_not session.alive?
    ensure
      ENV["PATH"] = original_path if original_path
      FileUtils.rm_rf(fake_bin) if fake_bin
    end

    test "send_message writes JSON to stdin when alive" do
      session = Earl::ClaudeSession.new(session_id: "test-session")

      # Use cat as a process that stays alive and echoes back
      stdin, stdout, stderr, wait_thread = Open3.popen3("cat")
      process_state = session.instance_variable_get(:@runtime).process_state
      process_state.stdin = stdin
      process_state.process = wait_thread

      result = session.send_message("Hello")
      stdin.close

      written = stdout.read
      parsed = JSON.parse(written.strip)

      assert_equal true, result
      assert_equal "user", parsed["type"]
      assert_equal "user", parsed.dig("message", "role")
      assert_equal "Hello", parsed.dig("message", "content")
    ensure
      [stdin, stdout, stderr].each do |io|
        io&.close
      rescue StandardError
        nil
      end
      begin
        wait_thread&.value
      rescue StandardError
        nil
      end
    end

    test "send_message returns false on IOError" do
      session = Earl::ClaudeSession.new(session_id: "test-session")

      # Use a process that stays alive
      stdin, stdout, stderr, wait_thread = Open3.popen3("cat")
      process_state = session.instance_variable_get(:@runtime).process_state
      process_state.stdin = stdin
      process_state.process = wait_thread

      # Close stdin to trigger IOError on write
      stdin.close

      result = session.send_message("Hello")
      assert_equal false, result
    ensure
      [stdin, stdout, stderr].each do |io|
        io&.close
      rescue StandardError
        nil
      end
      begin
        wait_thread&.value
      rescue StandardError
        nil
      end
    end

    test "send_message does not reset stats when write fails" do
      session = Earl::ClaudeSession.new(session_id: "test-session")

      # Set some stats that should NOT be reset on failure
      session.stats.turn_input_tokens = 500
      session.stats.turn_output_tokens = 200
      session.stats.message_sent_at = Time.now - 10

      # Use a process that stays alive but close stdin
      stdin, stdout, stderr, wait_thread = Open3.popen3("cat")
      process_state = session.instance_variable_get(:@runtime).process_state
      process_state.stdin = stdin
      process_state.process = wait_thread
      stdin.close

      session.send_message("Hello")

      # Stats should still reflect the previous turn (not reset)
      assert_equal 500, session.stats.turn_input_tokens
      assert_equal 200, session.stats.turn_output_tokens
    ensure
      [stdin, stdout, stderr].each do |io|
        io&.close
      rescue StandardError
        nil
      end
      begin
        wait_thread&.value
      rescue StandardError
        nil
      end
    end

    test "kill handles already-dead process gracefully" do
      session = Earl::ClaudeSession.new

      # Spawn a process that exits immediately
      stdin, _stdout, _stderr, wait_thread = Open3.popen3("true")
      wait_thread.value # wait for it to exit

      process_state = session.instance_variable_get(:@runtime).process_state
      process_state.process = wait_thread
      process_state.stdin = stdin

      assert_nothing_raised { session.kill }
    ensure
      [stdin, _stdout, _stderr].each do |io|
        io&.close
      rescue StandardError
        nil
      end
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
                                  "message" => { "content" => [{ "type" => "text", "text" => "parsed" }] }
                                })
      stdout = StringIO.new("#{json_line}\n")
      session.send(:read_stdout, stdout)

      assert_equal "parsed", received_text
    end

    test "read_stdout skips invalid JSON lines" do
      session = Earl::ClaudeSession.new
      received_text = nil
      session.on_text { |text| received_text = text }

      json_line = JSON.generate({
                                  "type" => "assistant",
                                  "message" => { "content" => [{ "type" => "text", "text" => "valid" }] }
                                })
      lines = "not json\n#{json_line}\n"
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
      process_state = session.instance_variable_get(:@runtime).process_state
      process_state.process = wait_thread
      process_state.stdin = stdin

      assert wait_thread.alive?
      session.kill
      # Process may take a moment to exit after TERM
      sleep 0.2
      assert_not wait_thread.alive?
    ensure
      [stdin, stdout, stderr].each do |io|
        io&.close
      rescue StandardError
        nil
      end
      begin
        wait_thread&.value
      rescue StandardError
        nil
      end
    end

    test "kill handles process that dies from first INT" do
      session = Earl::ClaudeSession.new

      # sleep doesn't trap INT so it dies from the first signal
      stdin, stdout, stderr, wait_thread = Open3.popen3("sleep", "60")
      sleep 0.2
      process_state = session.instance_variable_get(:@runtime).process_state
      process_state.process = wait_thread
      process_state.stdin = stdin

      assert wait_thread.alive?
      session.kill
      sleep 0.1
      assert_not wait_thread.alive?
    ensure
      [stdin, stdout, stderr].each do |io|
        io&.close
      rescue StandardError
        nil
      end
      begin
        wait_thread&.value
      rescue StandardError
        nil
      end
    end

    test "kill handles nil stdin and joins threads" do
      session = Earl::ClaudeSession.new

      stdin, _stdout, _stderr, wait_thread = Open3.popen3("true")
      wait_thread.value

      reader = Thread.new {}
      stderr_t = Thread.new {}
      reader.join
      stderr_t.join

      process_state = session.instance_variable_get(:@runtime).process_state
      process_state.process = wait_thread
      # Leave stdin as nil (default) to cover &. nil branch
      process_state.reader_thread = reader
      process_state.stderr_thread = stderr_t

      assert_nothing_raised { session.kill }
    ensure
      [stdin, _stdout, _stderr].each do |io|
        io&.close
      rescue StandardError
        nil
      end
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
      assert_equal 0.05, session.stats.total_cost
    end

    # --- CLI args tests ---

    test "cli_args includes --dangerously-skip-permissions without permission_config" do
      session = Earl::ClaudeSession.new
      args = session.send(:cli_args)

      assert_includes args, "--dangerously-skip-permissions"
      assert_not_includes args, "--permission-prompt-tool"
    end

    test "cli_args includes --permission-prompt-tool with permission_config" do
      mcp_config = Earl::ClaudeSession::McpConfig.new(
        env: { "PLATFORM_URL" => "http://localhost" }, skip_permissions: false
      )
      session = Earl::ClaudeSession.new(permission_config: mcp_config)
      args = session.send(:cli_args)

      assert_includes args, "--permission-prompt-tool"
      assert_includes args, "mcp__earl__permission_prompt"
      assert_not_includes args, "--dangerously-skip-permissions"
    end

    test "cli_args includes both --dangerously-skip-permissions and --mcp-config when skip_permissions" do
      mcp_config = Earl::ClaudeSession::McpConfig.new(
        env: { "PLATFORM_URL" => "http://localhost" }, skip_permissions: true
      )
      session = Earl::ClaudeSession.new(permission_config: mcp_config)
      args = session.send(:cli_args)

      assert_includes args, "--dangerously-skip-permissions"
      assert_includes args, "--mcp-config"
      assert_not_includes args, "--permission-prompt-tool"
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
      process_state = session.instance_variable_get(:@runtime).process_state
      process_state.stdin = stdin
      process_state.process = wait_thread

      session.send_message("test")

      assert_equal 0, session.stats.turn_input_tokens
      assert_equal 0, session.stats.turn_output_tokens
      assert_nil session.stats.first_token_at
      assert_not_nil session.stats.message_sent_at
    ensure
      [stdin, stdout, stderr].each do |io|
        io&.close
      rescue StandardError
        nil
      end
      begin
        wait_thread&.value
      rescue StandardError
        nil
      end
    end

    # --- System prompt args tests ---

    test "cli_args includes --append-system-prompt when memory exists" do
      tmp_dir = Dir.mktmpdir("earl-memory-cli-test")
      File.write(File.join(tmp_dir, "SOUL.md"), "I am EARL.")

      original_default = Earl::Memory::Store.default_dir
      Earl::Memory::Store.instance_variable_set(:@default_dir, tmp_dir)

      session = Earl::ClaudeSession.new
      args = session.send(:cli_args)

      assert_includes args, "--append-system-prompt"
      idx = args.index("--append-system-prompt")
      assert_includes args[idx + 1], "I am EARL."
      assert_includes args[idx + 1], "<earl-memory>"
    ensure
      Earl::Memory::Store.instance_variable_set(:@default_dir, original_default)
      FileUtils.rm_rf(tmp_dir)
    end

    test "cli_args omits --append-system-prompt when no memory" do
      tmp_dir = Dir.mktmpdir("earl-memory-cli-empty-test")

      original_default = Earl::Memory::Store.default_dir
      Earl::Memory::Store.instance_variable_set(:@default_dir, tmp_dir)

      session = Earl::ClaudeSession.new
      args = session.send(:cli_args)

      assert_not_includes args, "--append-system-prompt"
    ensure
      Earl::Memory::Store.instance_variable_set(:@default_dir, original_default)
      FileUtils.rm_rf(tmp_dir)
    end

    # --- Username tests ---

    test "initialize accepts username option" do
      session = Earl::ClaudeSession.new(username: "ericboehs")
      options = session.instance_variable_get(:@options)
      assert_equal "ericboehs", options.username
    end

    test "write_mcp_config includes EARL_CURRENT_USERNAME in env" do
      with_mcp_config_dir do
        session = Earl::ClaudeSession.new(
          permission_config: stub_mcp_config,
          username: "ericboehs"
        )
        path = session.send(:write_mcp_config)
        config = JSON.parse(File.read(path))

        env = config.dig("mcpServers", "earl", "env")
        assert_equal "ericboehs", env["EARL_CURRENT_USERNAME"]
      end
    end

    test "write_mcp_config uses earl as server name" do
      with_mcp_config_dir do
        session = Earl::ClaudeSession.new(
          permission_config: stub_mcp_config
        )
        path = session.send(:write_mcp_config)
        config = JSON.parse(File.read(path))

        assert config.dig("mcpServers", "earl"), "Expected 'earl' key in mcpServers"
        assert_nil config.dig("mcpServers", "earl_permissions"), "Should not have old 'earl_permissions' key"
      end
    end

    test "write_mcp_config creates file with 0600 permissions" do
      with_mcp_config_dir do
        session = Earl::ClaudeSession.new(
          permission_config: stub_mcp_config
        )
        path = session.send(:write_mcp_config)

        mode = File.stat(path).mode & 0o777
        assert_equal 0o600, mode, "Expected MCP config file to have 0600 permissions, got #{format("%04o", mode)}"
      end
    end

    test "write_mcp_config writes to ~/.config/earl/mcp/ directory" do
      with_mcp_config_dir do |mcp_dir|
        session = Earl::ClaudeSession.new(
          permission_config: stub_mcp_config
        )
        path = session.send(:write_mcp_config)

        assert path.start_with?(mcp_dir), "Expected path to start with #{mcp_dir}, got #{path}"
        assert_match(/earl-mcp-.*\.json\z/, File.basename(path))
      end
    end

    test "write_mcp_config merges user-defined MCP servers" do
      with_mcp_config_dir do
        user_servers = {
          "mcpServers" => {
            "apple-mail" => { "command" => "/usr/bin/mail", "args" => [] },
            "mcp-ical" => { "command" => "/usr/bin/ical", "args" => [] }
          }
        }
        File.write(Earl::ClaudeSession.user_mcp_servers_path, JSON.generate(user_servers))

        session = Earl::ClaudeSession.new(
          permission_config: stub_mcp_config
        )
        path = session.send(:write_mcp_config)
        config = JSON.parse(File.read(path))
        servers = config["mcpServers"]

        assert servers.key?("earl"), "Expected earl server"
        assert servers.key?("apple-mail"), "Expected apple-mail server"
        assert servers.key?("mcp-ical"), "Expected mcp-ical server"
      end
    end

    test "write_mcp_config earl server takes precedence over user-defined" do
      with_mcp_config_dir do
        user_servers = {
          "mcpServers" => {
            "earl" => { "command" => "/usr/bin/fake-earl", "args" => ["--bad"] }
          }
        }
        File.write(Earl::ClaudeSession.user_mcp_servers_path, JSON.generate(user_servers))

        session = Earl::ClaudeSession.new(
          permission_config: stub_mcp_config
        )
        path = session.send(:write_mcp_config)
        config = JSON.parse(File.read(path))
        earl_server = config.dig("mcpServers", "earl")

        assert_not_equal "/usr/bin/fake-earl", earl_server["command"]
        assert_includes earl_server["command"], "earl-permission-server"
      end
    end

    test "write_mcp_config handles missing mcp_servers.json gracefully" do
      with_mcp_config_dir do
        session = Earl::ClaudeSession.new(
          permission_config: stub_mcp_config
        )
        path = session.send(:write_mcp_config)
        config = JSON.parse(File.read(path))

        assert_equal 1, config["mcpServers"].size
        assert config.dig("mcpServers", "earl")
      end
    end

    test "write_mcp_config handles malformed mcp_servers.json gracefully" do
      with_mcp_config_dir do
        File.write(Earl::ClaudeSession.user_mcp_servers_path, "not valid json{{{")

        session = Earl::ClaudeSession.new(
          permission_config: stub_mcp_config
        )
        path = session.send(:write_mcp_config)
        config = JSON.parse(File.read(path))

        assert_equal 1, config["mcpServers"].size
        assert config.dig("mcpServers", "earl")
      end
    end

    test "write_mcp_config handles mcp_servers.json without mcpServers key" do
      with_mcp_config_dir do
        File.write(Earl::ClaudeSession.user_mcp_servers_path, JSON.generate({ "other" => "data" }))

        session = Earl::ClaudeSession.new(
          permission_config: stub_mcp_config
        )
        path = session.send(:write_mcp_config)
        config = JSON.parse(File.read(path))

        assert_equal 1, config["mcpServers"].size
        assert config.dig("mcpServers", "earl")
      end
    end

    test "cleanup_mcp_configs removes stale config files" do
      with_mcp_config_dir do |mcp_dir|
        FileUtils.mkdir_p(mcp_dir)
        stale_path = File.join(mcp_dir, "earl-mcp-stale-session-id.json")
        active_path = File.join(mcp_dir, "earl-mcp-active-session-id.json")
        File.write(stale_path, "{}")
        File.write(active_path, "{}")

        Earl::ClaudeSession.cleanup_mcp_configs(active_session_ids: ["active-session-id"])

        assert_not File.exist?(stale_path), "Expected stale config to be removed"
        assert File.exist?(active_path), "Expected active config to be preserved"
      end
    end

    test "cleanup_mcp_configs removes all files when no active sessions" do
      with_mcp_config_dir do |mcp_dir|
        FileUtils.mkdir_p(mcp_dir)
        path = File.join(mcp_dir, "earl-mcp-old-session.json")
        File.write(path, "{}")

        Earl::ClaudeSession.cleanup_mcp_configs

        assert_not File.exist?(path), "Expected config to be removed"
      end
    end

    test "cleanup_mcp_configs handles missing directory gracefully" do
      with_mcp_config_dir do
        assert_nothing_raised { Earl::ClaudeSession.cleanup_mcp_configs }
      end
    end

    test "stats tokens_per_second returns nil when duration is zero" do
      session = Earl::ClaudeSession.new
      now = Time.now
      session.stats.first_token_at = now
      session.stats.complete_at = now # zero duration
      session.stats.turn_output_tokens = 100

      assert_nil session.stats.tokens_per_second
    end

    test "stats context_percent returns nil when context_tokens are zero" do
      session = Earl::ClaudeSession.new
      session.stats.context_window = 200_000
      session.stats.turn_input_tokens = 0
      session.stats.cache_read_tokens = 0
      session.stats.cache_creation_tokens = 0

      assert_nil session.stats.context_percent
    end

    test "earl_project_dir returns default path when EARL_CLAUDE_HOME not set" do
      original = ENV.delete("EARL_CLAUDE_HOME")
      session = Earl::ClaudeSession.new
      expected = File.join(Earl.config_root, "claude-home")
      assert_equal expected, session.send(:earl_project_dir)
    ensure
      ENV["EARL_CLAUDE_HOME"] = original if original
    end

    test "earl_project_dir respects EARL_CLAUDE_HOME env var" do
      original = ENV.fetch("EARL_CLAUDE_HOME", nil)
      ENV["EARL_CLAUDE_HOME"] = "/tmp/custom-claude-home"
      session = Earl::ClaudeSession.new
      assert_equal "/tmp/custom-claude-home", session.send(:earl_project_dir)
    ensure
      if original
        ENV["EARL_CLAUDE_HOME"] = original
      else
        ENV.delete("EARL_CLAUDE_HOME")
      end
    end

    test "open_process uses no chdir when working_dir is nil" do
      session = Earl::ClaudeSession.new(working_dir: nil)
      args = session.send(:cli_args)
      assert_includes args, "claude"
    end

    test "handle_event result with empty modelUsage hash" do
      session = Earl::ClaudeSession.new
      session.on_complete { |_sess| }

      event = {
        "type" => "result", "subtype" => "success",
        "modelUsage" => {}
      }
      session.send(:handle_event, event)

      assert_equal 0, session.stats.total_input_tokens
    end

    test "handle_event result with modelUsage missing contextWindow" do
      session = Earl::ClaudeSession.new
      session.on_complete { |_sess| }

      event = {
        "type" => "result", "subtype" => "success",
        "modelUsage" => {
          "claude-sonnet-4-20250514" => {
            "inputTokens" => 100, "outputTokens" => 50
          }
        }
      }
      session.send(:handle_event, event)

      assert_nil session.stats.context_window
    end

    test "format_timing returns nil when no timing data" do
      session = Earl::ClaudeSession.new
      result = session.send(:format_timing)
      assert_nil result
    end

    test "format_context_usage returns nil when no context" do
      session = Earl::ClaudeSession.new
      result = session.send(:format_context_usage)
      assert_nil result
    end

    # --- working_dir accessor ---

    test "working_dir returns configured directory" do
      session = Earl::ClaudeSession.new(working_dir: "/tmp/test-project")
      assert_equal "/tmp/test-project", session.working_dir
    end

    test "working_dir returns nil when not configured" do
      session = Earl::ClaudeSession.new
      assert_nil session.working_dir
    end

    # --- emit_images_from_result with texts ---

    test "handle_event fires on_tool_result with images and texts for user tool_result events" do
      session = Earl::ClaudeSession.new
      received = nil
      session.on_tool_result { |data| received = data }

      event = {
        "type" => "user",
        "message" => {
          "content" => [
            {
              "type" => "tool_result",
              "content" => [
                { "type" => "image", "source" => { "data" => "iVBOR#{"A" * 200}", "media_type" => "image/png" } },
                { "type" => "text", "text" => ".playwright-mcp/page-1.png" }
              ]
            }
          ]
        }
      }
      session.send(:handle_event, event)

      assert_not_nil received
      assert_equal 1, received[:images].size
      assert_equal "image", received[:images][0]["type"]
      assert_equal [".playwright-mcp/page-1.png"], received[:texts]
    end

    test "handle_event fires on_tool_result for texts-only tool_result" do
      session = Earl::ClaudeSession.new
      received = nil
      session.on_tool_result { |data| received = data }

      event = {
        "type" => "user",
        "message" => {
          "content" => [
            {
              "type" => "tool_result",
              "content" => [
                { "type" => "text", "text" => ".playwright-mcp/screenshot.png" }
              ]
            }
          ]
        }
      }
      session.send(:handle_event, event)

      assert_not_nil received
      assert_empty received[:images]
      assert_equal [".playwright-mcp/screenshot.png"], received[:texts]
    end

    test "handle_event skips on_tool_result when no images or texts" do
      session = Earl::ClaudeSession.new
      called = false
      session.on_tool_result { |_| called = true }

      event = {
        "type" => "user",
        "message" => {
          "content" => [
            {
              "type" => "tool_result",
              "content" => [
                { "type" => "other", "data" => "something" }
              ]
            }
          ]
        }
      }
      session.send(:handle_event, event)

      assert_not called
    end

    test "stats format_summary includes all optional fields when present" do
      session = Earl::ClaudeSession.new
      session.stats.total_input_tokens = 5000
      session.stats.total_output_tokens = 1500
      session.stats.turn_input_tokens = 1000
      session.stats.turn_output_tokens = 500
      session.stats.cache_read_tokens = 3000
      session.stats.cache_creation_tokens = 1000
      session.stats.context_window = 200_000
      session.stats.model_id = "claude-sonnet-4-20250514"
      session.stats.message_sent_at = Time.now - 2.0
      session.stats.first_token_at = Time.now - 1.0
      session.stats.complete_at = Time.now

      summary = session.stats.format_summary("Test")
      assert_includes summary, "Test:"
      assert_includes summary, "6500 tokens"
      assert_includes summary, "context"
      assert_includes summary, "TTFT"
      assert_includes summary, "tok/s"
      assert_includes summary, "model=claude-sonnet-4-20250514"
    end

    test "format_timing returns timing string when data present" do
      session = Earl::ClaudeSession.new
      session.stats.message_sent_at = Time.now - 2.0
      session.stats.first_token_at = Time.now - 1.0
      session.stats.complete_at = Time.now
      session.stats.turn_output_tokens = 100

      result = session.send(:format_timing)
      assert_not_nil result
      assert_includes result, "TTFT"
      assert_includes result, "tok/s"
    end

    test "format_context_usage returns string when context data present" do
      session = Earl::ClaudeSession.new
      session.stats.context_window = 200_000
      session.stats.turn_input_tokens = 10_000
      session.stats.cache_read_tokens = 5_000
      session.stats.cache_creation_tokens = 5_000

      result = session.send(:format_context_usage)
      assert_not_nil result
      assert_includes result, "context used"
    end

    test "stats format_summary omits optional fields when nil" do
      session = Earl::ClaudeSession.new
      summary = session.stats.format_summary("Test")
      assert_includes summary, "Test:"
      assert_includes summary, "0 tokens"
      assert_not_includes summary, "context"
      assert_not_includes summary, "TTFT"
      assert_not_includes summary, "tok/s"
      assert_not_includes summary, "model="
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

    test "stats tokens_per_second returns nil with nil turn_output_tokens" do
      session = Earl::ClaudeSession.new
      session.stats.first_token_at = Time.now - 2.0
      session.stats.complete_at = Time.now
      session.stats.turn_output_tokens = nil

      assert_nil session.stats.tokens_per_second
    end

    # --- content_preview branch: Array content ---

    test "content_preview returns block count for Array content" do
      session = Earl::ClaudeSession.new
      content = [{ "type" => "text", "text" => "hello" }, { "type" => "image" }]
      result = session.send(:content_preview, content)
      assert_equal "[2 content blocks]", result
    end

    # --- handle_user_event branch: non-Array content ---

    test "handle_user_event skips non-Array content" do
      session = Earl::ClaudeSession.new
      called = false
      session.on_tool_result { |_result| called = true }

      event = { "type" => "user", "message" => { "content" => "plain string" } }
      session.send(:handle_event, event)

      assert_not called
    end

    test "handle_user_event skips nil content" do
      session = Earl::ClaudeSession.new
      called = false
      session.on_tool_result { |_result| called = true }

      event = { "type" => "user", "message" => {} }
      session.send(:handle_event, event)

      assert_not called
    end

    # --- emit_tool_result_images branch: items without tool_result type ---

    test "emit_tool_result_images skips non-tool_result items" do
      session = Earl::ClaudeSession.new
      called = false
      session.on_tool_result { |_result| called = true }

      event = {
        "type" => "user",
        "message" => {
          "content" => [
            { "type" => "text", "text" => "just text" },
            { "type" => "image", "source" => {} }
          ]
        }
      }
      session.send(:handle_event, event)

      assert_not called
    end

    # --- emit_images_from_result branch: non-Array nested content ---

    test "emit_images_from_result skips tool_result with non-Array content" do
      session = Earl::ClaudeSession.new
      called = false
      session.on_tool_result { |_result| called = true }

      event = {
        "type" => "user",
        "message" => {
          "content" => [
            { "type" => "tool_result", "content" => "plain string result" }
          ]
        }
      }
      session.send(:handle_event, event)

      assert_not called
    end

    test "emit_images_from_result skips tool_result with nil content" do
      session = Earl::ClaudeSession.new
      called = false
      session.on_tool_result { |_result| called = true }

      event = {
        "type" => "user",
        "message" => {
          "content" => [
            { "type" => "tool_result" }
          ]
        }
      }
      session.send(:handle_event, event)

      assert_not called
    end

    private

    def scratchpad_dir
      dir = File.join(Dir.tmpdir, "earl-tests")
      FileUtils.mkdir_p(dir)
      dir
    end

    def with_mcp_config_dir
      tmp_dir = Dir.mktmpdir("earl-mcp-test")
      mcp_dir = File.join(tmp_dir, "mcp")
      user_servers_path = File.join(tmp_dir, "mcp_servers.json")

      original_mcp_dir = Earl::ClaudeSession.mcp_config_dir
      original_user_path = Earl::ClaudeSession.user_mcp_servers_path
      Earl::ClaudeSession.instance_variable_set(:@mcp_config_dir, mcp_dir)
      Earl::ClaudeSession.instance_variable_set(:@user_mcp_servers_path, user_servers_path)

      yield mcp_dir
    ensure
      Earl::ClaudeSession.instance_variable_set(:@mcp_config_dir, original_mcp_dir)
      Earl::ClaudeSession.instance_variable_set(:@user_mcp_servers_path, original_user_path)
      FileUtils.rm_rf(tmp_dir)
    end
  end
end
