require "test_helper"

class Earl::CommandExecutorTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)

    @original_env = ENV.to_h.slice(
      "MATTERMOST_URL", "MATTERMOST_BOT_TOKEN", "MATTERMOST_BOT_ID",
      "EARL_CHANNEL_ID", "EARL_ALLOWED_USERS", "EARL_SKIP_PERMISSIONS"
    )

    ENV["MATTERMOST_URL"] = "https://mattermost.example.com"
    ENV["MATTERMOST_BOT_TOKEN"] = "test-token"
    ENV["MATTERMOST_BOT_ID"] = "bot-123"
    ENV["EARL_CHANNEL_ID"] = "channel-456"
    ENV["EARL_ALLOWED_USERS"] = ""
    ENV["EARL_SKIP_PERMISSIONS"] = "true"
  end

  teardown do
    Earl.logger = nil
    %w[MATTERMOST_URL MATTERMOST_BOT_TOKEN MATTERMOST_BOT_ID EARL_CHANNEL_ID EARL_ALLOWED_USERS EARL_SKIP_PERMISSIONS].each do |key|
      if @original_env.key?(key)
        ENV[key] = @original_env[key]
      else
        ENV.delete(key)
      end
    end
  end

  test "!help posts help table" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :help, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, posted.size
    assert_includes posted.first[:message], "!help"
    assert_includes posted.first[:message], "!stats"
  end

  test "!stats posts session stats table" do
    posted = []
    mock_session = Object.new
    mock_stats = Earl::ClaudeSession::Stats.new(
      total_cost: 0.1234, total_input_tokens: 5000, total_output_tokens: 1500,
      turn_input_tokens: 500, turn_output_tokens: 200,
      cache_read_tokens: 100, cache_creation_tokens: 50,
      context_window: 200_000, model_id: "claude-sonnet-4-20250514"
    )
    mock_session.define_singleton_method(:stats) { mock_stats }

    executor = build_executor(posted: posted, session: mock_session)
    command = Earl::CommandParser::ParsedCommand.new(name: :stats, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, posted.size
    message = posted.first[:message]
    assert_includes message, "6,500"
    assert_includes message, "5,000"
    assert_includes message, "1,500"
    assert_includes message, "claude-sonnet-4-20250514"
    assert_includes message, "0.1234"
    assert_includes message, "200,000"
  end

  test "!cost is alias for !stats" do
    posted = []
    mock_session = Object.new
    mock_stats = Earl::ClaudeSession::Stats.new(
      total_cost: 0.05, total_input_tokens: 1000, total_output_tokens: 500,
      turn_input_tokens: 100, turn_output_tokens: 50,
      cache_read_tokens: 0, cache_creation_tokens: 0
    )
    mock_session.define_singleton_method(:stats) { mock_stats }

    executor = build_executor(posted: posted, session: mock_session)
    command = Earl::CommandParser.parse("!cost")
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, posted.size
    assert_includes posted.first[:message], "Session Stats"
  end

  test "!stats reports no session" do
    posted = []
    executor = build_executor(posted: posted, session: nil)

    command = Earl::CommandParser::ParsedCommand.new(name: :stats, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "No active session"
  end

  test "!stats shows persisted stats for stopped session" do
    posted = []
    executor = build_executor(posted: posted, session: nil)

    persisted = Earl::SessionStore::PersistedSession.new(
      claude_session_id: "sess-123",
      total_cost: 0.5678,
      total_input_tokens: 10_000,
      total_output_tokens: 3_000
    )
    executor.instance_variable_get(:@deps).session_manager
            .define_singleton_method(:persisted_session_for) { |_id| persisted }

    command = Earl::CommandParser::ParsedCommand.new(name: :stats, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, posted.size
    message = posted.first[:message]
    assert_includes message, "stopped"
    assert_includes message, "13,000"
    assert_includes message, "10,000"
    assert_includes message, "3,000"
    assert_includes message, "0.5678"
  end

  test "!stats includes timing when available" do
    posted = []
    mock_session = Object.new
    mock_stats = Earl::ClaudeSession::Stats.new(
      total_cost: 0.05, total_input_tokens: 1000, total_output_tokens: 500,
      turn_input_tokens: 200, turn_output_tokens: 100,
      cache_read_tokens: 0, cache_creation_tokens: 0,
      context_window: 200_000, model_id: "claude-sonnet-4-20250514",
      message_sent_at: Time.now - 2.0, first_token_at: Time.now - 1.0,
      complete_at: Time.now
    )
    mock_session.define_singleton_method(:stats) { mock_stats }

    executor = build_executor(posted: posted, session: mock_session)
    command = Earl::CommandParser::ParsedCommand.new(name: :stats, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    message = posted.first[:message]
    assert_includes message, "TTFT"
    assert_includes message, "tok/s"
  end

  test "format_number adds commas" do
    executor = build_executor
    assert_equal "1,000", executor.send(:format_number, 1000)
    assert_equal "200,000", executor.send(:format_number, 200_000)
    assert_equal "42", executor.send(:format_number, 42)
    assert_equal "0", executor.send(:format_number, nil)
  end

  test "!stop stops session" do
    posted = []
    stopped = []
    executor = build_executor(posted: posted, stopped: stopped)

    command = Earl::CommandParser::ParsedCommand.new(name: :stop, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal [ "thread-1" ], stopped
    assert_includes posted.first[:message], "stopped"
  end

  test "!cd sets working directory for valid path" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :cd, args: [ "/tmp" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal "/tmp", executor.working_dir_for("thread-1")
    assert_includes posted.first[:message], "/tmp"
  end

  test "!cd reports invalid directory" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :cd, args: [ "/nonexistent/path/12345" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_nil executor.working_dir_for("thread-1")
    assert_includes posted.first[:message], "not found"
  end

  test "!cd with no args shows usage" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :cd, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Usage"
    assert_nil executor.working_dir_for("thread-1")
  end

  test "!cd with nil arg shows usage" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :cd, args: [ nil ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Usage"
  end

  test "!cd with whitespace-only arg shows usage" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :cd, args: [ "   " ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Usage"
  end

  test "!permissions shows info message" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :permissions, args: [ "auto" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "EARL_SKIP_PERMISSIONS"
  end

  test "!compact returns passthrough to /compact" do
    executor = build_executor

    command = Earl::CommandParser::ParsedCommand.new(name: :compact, args: [])
    result = executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal({ passthrough: "/compact" }, result)
  end

  test "!escape sends SIGINT to active session" do
    posted = []
    mock_session = Object.new
    mock_session.define_singleton_method(:process_pid) { 99999 }

    executor = build_executor(posted: posted, session: mock_session)

    # Stub Process.kill to avoid actually sending signals
    killed = []
    original_kill = Process.method(:kill)
    Process.define_singleton_method(:kill) do |signal, pid|
      killed << { signal: signal, pid: pid }
    end

    command = Earl::CommandParser::ParsedCommand.new(name: :escape, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal [ { signal: "INT", pid: 99999 } ], killed
    assert_includes posted.first[:message], "SIGINT"
  ensure
    Process.define_singleton_method(:kill) { |*args| original_kill.call(*args) } if original_kill
  end

  test "!escape reports no session when none active" do
    posted = []
    executor = build_executor(posted: posted, session: nil)

    command = Earl::CommandParser::ParsedCommand.new(name: :escape, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "No active session"
  end

  test "!kill force kills active session" do
    posted = []
    stopped = []
    mock_session = Object.new
    mock_session.define_singleton_method(:process_pid) { 99999 }

    executor = build_executor(posted: posted, session: mock_session, stopped: stopped)

    killed = []
    original_kill = Process.method(:kill)
    Process.define_singleton_method(:kill) do |signal, pid|
      killed << { signal: signal, pid: pid }
    end

    command = Earl::CommandParser::ParsedCommand.new(name: :kill, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal [ { signal: "KILL", pid: 99999 } ], killed
    assert_equal [ "thread-1" ], stopped
    assert_includes posted.first[:message], "force killed"
  ensure
    Process.define_singleton_method(:kill) { |*args| original_kill.call(*args) } if original_kill
  end

  test "!kill reports no session when none active" do
    posted = []
    executor = build_executor(posted: posted, session: nil)

    command = Earl::CommandParser::ParsedCommand.new(name: :kill, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "No active session"
  end

  test "!compact returns passthrough even without session" do
    executor = build_executor(session: nil)

    command = Earl::CommandParser::ParsedCommand.new(name: :compact, args: [])
    result = executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal({ passthrough: "/compact" }, result)
  end

  test "execute handles unknown command gracefully" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :unknown_cmd, args: [])
    # Should not raise — just falls through case statement
    assert_nothing_raised do
      executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")
    end
    assert_empty posted
  end

  test "!heartbeats posts status table with heartbeats" do
    posted = []
    mock_scheduler = Object.new
    mock_scheduler.define_singleton_method(:status) do
      [
        { name: "morning_briefing", description: "Morning briefing", next_run_at: Time.new(2026, 2, 14, 9, 0, 0),
          last_run_at: Time.new(2026, 2, 13, 9, 0, 0), run_count: 5, running: false, last_error: nil }
      ]
    end

    executor = build_executor(posted: posted, heartbeat_scheduler: mock_scheduler)

    command = Earl::CommandParser::ParsedCommand.new(name: :heartbeats, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, posted.size
    message = posted.first[:message]
    assert_includes message, "Heartbeat Status"
    assert_includes message, "morning_briefing"
    assert_includes message, "2026-02-14 09:00"
    assert_includes message, "2026-02-13 09:00"
    assert_includes message, "5"
    assert_includes message, "Idle"
  end

  test "!heartbeats shows running status" do
    posted = []
    mock_scheduler = Object.new
    mock_scheduler.define_singleton_method(:status) do
      [
        { name: "active_beat", description: "Active", next_run_at: nil,
          last_run_at: Time.now, run_count: 1, running: true, last_error: nil }
      ]
    end

    executor = build_executor(posted: posted, heartbeat_scheduler: mock_scheduler)

    command = Earl::CommandParser::ParsedCommand.new(name: :heartbeats, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Running"
  end

  test "!heartbeats shows error status" do
    posted = []
    mock_scheduler = Object.new
    mock_scheduler.define_singleton_method(:status) do
      [
        { name: "broken_beat", description: "Broken", next_run_at: Time.now + 3600,
          last_run_at: Time.now - 3600, run_count: 3, running: false, last_error: "timeout" }
      ]
    end

    executor = build_executor(posted: posted, heartbeat_scheduler: mock_scheduler)

    command = Earl::CommandParser::ParsedCommand.new(name: :heartbeats, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Error"
  end

  test "!heartbeats reports no heartbeats configured" do
    posted = []
    mock_scheduler = Object.new
    mock_scheduler.define_singleton_method(:status) { [] }

    executor = build_executor(posted: posted, heartbeat_scheduler: mock_scheduler)

    command = Earl::CommandParser::ParsedCommand.new(name: :heartbeats, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "No heartbeats configured"
  end

  test "!heartbeats reports scheduler not configured" do
    posted = []
    executor = build_executor(posted: posted, heartbeat_scheduler: nil)

    command = Earl::CommandParser::ParsedCommand.new(name: :heartbeats, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "not configured"
  end

  test "!help includes heartbeats command" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :help, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "!heartbeats"
  end

  test "!help includes usage command" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :help, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "!usage"
  end

  test "!usage posts loading message and then usage data" do
    posted = []
    executor = build_executor(posted: posted)

    usage_json = {
      "session" => { "percent_used" => 66, "resets" => "5pm (America/Chicago)" },
      "week" => { "percent_used" => 34, "resets" => "Feb 19 at 3:59pm (America/Chicago)" },
      "extra" => { "percent_used" => 52, "spent" => "$10.47", "budget" => "$20.00", "resets" => "Mar 1 (America/Chicago)" }
    }
    executor.define_singleton_method(:fetch_usage_data) { usage_json }

    command = Earl::CommandParser::ParsedCommand.new(name: :usage, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    # Wait for the background thread to complete
    sleep 0.2

    assert_equal 2, posted.size
    assert_includes posted[0][:message], "Fetching usage"
    assert_includes posted[1][:message], "66% used"
    assert_includes posted[1][:message], "34% used"
    assert_includes posted[1][:message], "$10.47 / $20.00"
  end

  test "!usage posts error when fetch fails" do
    posted = []
    executor = build_executor(posted: posted)

    executor.define_singleton_method(:fetch_usage_data) { nil }

    command = Earl::CommandParser::ParsedCommand.new(name: :usage, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    sleep 0.2

    assert_equal 2, posted.size
    assert_includes posted[0][:message], "Fetching usage"
    assert_includes posted[1][:message], "Failed to fetch"
  end

  test "format_usage formats all sections" do
    executor = build_executor
    data = {
      "session" => { "percent_used" => 80, "resets" => "5pm" },
      "week" => { "percent_used" => 45, "resets" => "Feb 19" },
      "extra" => { "percent_used" => 30, "spent" => "$6.00", "budget" => "$20.00", "resets" => "Mar 1" }
    }

    result = executor.send(:format_usage, data)
    assert_includes result, "Claude Pro Usage"
    assert_includes result, "80% used"
    assert_includes result, "45% used"
    assert_includes result, "$6.00 / $20.00"
  end

  test "!help includes context command" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :help, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "!context"
  end

  test "!context reports no session when none found" do
    posted = []
    executor = build_executor(posted: posted, session: nil)

    command = Earl::CommandParser::ParsedCommand.new(name: :context, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, posted.size
    assert_includes posted.first[:message], "No session found"
  end

  test "!context works for closed sessions via session store" do
    posted = []
    executor = build_executor(posted: posted, session: nil)

    # Override claude_session_id_for to simulate a persisted (closed) session
    executor.instance_variable_get(:@deps).session_manager
            .define_singleton_method(:claude_session_id_for) { |_id| "persisted-abc-123" }

    context_json = {
      "model" => "claude-opus-4-6",
      "used_tokens" => "150k",
      "total_tokens" => "200k",
      "percent_used" => "75%",
      "categories" => {
        "messages" => { "tokens" => "100k", "percent" => "50.0%" }
      }
    }
    executor.define_singleton_method(:fetch_context_data) { |_sid| context_json }

    command = Earl::CommandParser::ParsedCommand.new(name: :context, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")
    sleep 0.2

    assert_equal 2, posted.size
    assert_includes posted[0][:message], "Fetching context"
    assert_includes posted[1][:message], "150k / 200k"
  end

  test "!context posts loading message and then context data" do
    posted = []
    mock_session = Object.new
    mock_session.define_singleton_method(:session_id) { "abc-123" }

    executor = build_executor(posted: posted, session: mock_session)
    context_json = {
      "model" => "claude-opus-4-6",
      "used_tokens" => "79k",
      "total_tokens" => "200k",
      "percent_used" => "39%",
      "categories" => {
        "messages" => { "tokens" => "27.5k", "percent" => "13.8%" },
        "system_tools" => { "tokens" => "23.7k", "percent" => "11.9%" },
        "free_space" => { "tokens" => "106k", "percent" => "53.0%" }
      }
    }
    executor.define_singleton_method(:fetch_context_data) { |_sid| context_json }

    command = Earl::CommandParser::ParsedCommand.new(name: :context, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")
    sleep 0.2

    assert_equal 2, posted.size
    assert_includes posted[0][:message], "Fetching context"
    assert_includes posted[1][:message], "79k / 200k"
    assert_includes posted[1][:message], "27.5k tokens (13.8%)"
    assert_includes posted[1][:message], "claude-opus-4-6"
  end

  test "!context posts error when fetch fails" do
    posted = []
    mock_session = Object.new
    mock_session.define_singleton_method(:session_id) { "abc-123" }

    executor = build_executor(posted: posted, session: mock_session)
    executor.define_singleton_method(:fetch_context_data) { |_sid| nil }

    command = Earl::CommandParser::ParsedCommand.new(name: :context, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")
    sleep 0.2

    assert_equal 2, posted.size
    assert_includes posted[0][:message], "Fetching context"
    assert_includes posted[1][:message], "Failed to fetch"
  end

  test "format_context formats all categories" do
    executor = build_executor
    data = {
      "model" => "claude-opus-4-6",
      "used_tokens" => "79k",
      "total_tokens" => "200k",
      "percent_used" => "39%",
      "categories" => {
        "messages" => { "tokens" => "27.5k", "percent" => "13.8%" },
        "system_prompt" => { "tokens" => "3k", "percent" => "1.5%" },
        "system_tools" => { "tokens" => "23.7k", "percent" => "11.9%" },
        "free_space" => { "tokens" => "106k", "percent" => "53.0%" },
        "autocompact_buffer" => { "tokens" => "33k", "percent" => "16.5%" }
      }
    }

    result = executor.send(:format_context, data)
    assert_includes result, "Context Window Usage"
    assert_includes result, "claude-opus-4-6"
    assert_includes result, "79k / 200k tokens (39%)"
    assert_includes result, "**Messages:** 27.5k tokens (13.8%)"
    assert_includes result, "**Free space:** 106k tokens (53.0%)"
    assert_includes result, "**Autocompact buffer:** 33k tokens (16.5%)"
  end

  test "format_context handles missing categories gracefully" do
    executor = build_executor
    data = {
      "model" => "claude-opus-4-6",
      "used_tokens" => "34k",
      "total_tokens" => "200k",
      "percent_used" => "17%",
      "categories" => {
        "messages" => { "tokens" => nil, "percent" => nil }
      }
    }

    result = executor.send(:format_context, data)
    assert_includes result, "Context Window Usage"
    assert_not_includes result, "Messages"
  end

  test "!help includes tmux session commands" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :help, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    message = posted.first[:message]
    assert_includes message, "!sessions"
    assert_includes message, "!session"
    assert_includes message, "!spawn"
  end

  test "!sessions lists Claude panes with project and status" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.available_result = true
    tmux.list_all_panes_result = [
      { target: "code:1.0", session: "code", window: 1, pane_index: 0,
        command: "2.1.42", path: "/home/user/earl", pid: 100, tty: "/dev/ttys001" },
      { target: "code:2.0", session: "code", window: 2, pane_index: 0,
        command: "2.1.42", path: "/home/user/mpi-poc", pid: 200, tty: "/dev/ttys002" },
      { target: "chat:1.0", session: "chat", window: 1, pane_index: 0,
        command: "weechat", path: "/home/user", pid: 300, tty: "/dev/ttys003" }
    ]
    tmux.claude_on_tty_results = { "/dev/ttys001" => true, "/dev/ttys002" => true, "/dev/ttys003" => false }
    tmux.capture_pane_result = "working on stuff\n"

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :sessions, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, posted.size
    msg = posted.first[:message]
    assert_includes msg, "Claude Sessions (2)"
    assert_includes msg, "code:1.0"
    assert_includes msg, "earl"
    assert_includes msg, "code:2.0"
    assert_includes msg, "mpi-poc"
    assert_not_includes msg, "chat:1.0"
    assert_not_includes msg, "weechat"
  end

  test "!sessions shows active status when esc to interrupt present" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.available_result = true
    tmux.list_all_panes_result = [
      { target: "code:1.0", session: "code", window: 1, pane_index: 0,
        command: "2.1.42", path: "/home/user/earl", pid: 100, tty: "/dev/ttys001" }
    ]
    tmux.claude_on_tty_results = { "/dev/ttys001" => true }
    tmux.capture_pane_result = "working on stuff\nesc to interrupt\n"

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :sessions, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Active"
  end

  test "!sessions shows permission status when Do you want to proceed present" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.available_result = true
    tmux.list_all_panes_result = [
      { target: "code:1.0", session: "code", window: 1, pane_index: 0,
        command: "2.1.42", path: "/home/user/earl", pid: 100, tty: "/dev/ttys001" }
    ]
    tmux.claude_on_tty_results = { "/dev/ttys001" => true }
    tmux.capture_pane_result = "Do you want to proceed?\n> 1. Yes\n  2. No\nEsc to cancel\n"

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :sessions, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Waiting for permission"
  end

  test "!sessions shows permission status even when esc to interrupt is also present" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.available_result = true
    tmux.list_all_panes_result = [
      { target: "code:1.0", session: "code", window: 1, pane_index: 0,
        command: "2.1.42", path: "/home/user/earl", pid: 100, tty: "/dev/ttys001" }
    ]
    tmux.claude_on_tty_results = { "/dev/ttys001" => true }
    tmux.capture_pane_result = "esc to interrupt\nDo you want to proceed?\n> 1. Yes\n  2. No\n"

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :sessions, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    # Permission takes priority over active
    assert_includes posted.first[:message], "Waiting for permission"
    assert_not_includes posted.first[:message], "Active"
  end

  test "!sessions reports when tmux not available" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.available_result = false

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :sessions, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "not installed"
  end

  test "!sessions reports when no panes exist" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.available_result = true
    tmux.list_all_panes_result = []

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :sessions, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "No tmux sessions"
  end

  test "!sessions reports when no Claude sessions found" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.available_result = true
    tmux.list_all_panes_result = [
      { target: "chat:1.0", session: "chat", window: 1, pane_index: 0,
        command: "weechat", path: "/home/user", pid: 300, tty: "/dev/ttys003" }
    ]
    tmux.claude_on_tty_results = { "/dev/ttys003" => false }

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :sessions, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "No Claude sessions found"
  end

  test "!session <name> shows pane output" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.capture_pane_result = "some output text"

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :session_show, args: [ "dev" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "some output text"
    assert_includes posted.first[:message], "dev"
  end

  test "!session <name> truncates long output" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.capture_pane_result = "x" * 4000

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :session_show, args: [ "dev" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "…"
    assert posted.first[:message].length < 4100
  end

  test "!session <name> reports missing session" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.capture_pane_error = Earl::Tmux::NotFound.new("not found")

    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :session_show, args: [ "missing" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "not found"
  end

  test "!session <name> kill kills session and removes from store" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux_store = build_tmux_store
    executor = build_executor(posted: posted, tmux_store: tmux_store, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :session_kill, args: [ "dev" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal [ "dev" ], tmux.killed_sessions
    assert_includes posted.first[:message], "killed"
    assert_includes tmux_store[:deleted], "dev"
  end

  test "!session <name> nudge sends nudge message" do
    posted = []
    tmux = build_mock_tmux_adapter
    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :session_nudge, args: [ "dev" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, tmux.send_keys_calls.size
    assert_equal "dev", tmux.send_keys_calls.first[:target]
    assert_includes tmux.send_keys_calls.first[:text], "stuck"
    assert_includes posted.first[:message], "Nudged"
  end

  test "!session <name> approve sends Enter to approve permission" do
    posted = []
    tmux = build_mock_tmux_adapter
    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :session_approve, args: [ "code:4.0" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, tmux.send_keys_raw_calls.size
    assert_equal "code:4.0", tmux.send_keys_raw_calls.first[:target]
    assert_equal "Enter", tmux.send_keys_raw_calls.first[:key]
    assert_includes posted.first[:message], "Approved"
  end

  test "!session <name> deny sends Escape to deny permission" do
    posted = []
    tmux = build_mock_tmux_adapter
    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :session_deny, args: [ "code:4.0" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, tmux.send_keys_raw_calls.size
    assert_equal "code:4.0", tmux.send_keys_raw_calls.first[:target]
    assert_equal "Escape", tmux.send_keys_raw_calls.first[:key]
    assert_includes posted.first[:message], "Denied"
  end

  test "!session <name> 'text' sends input" do
    posted = []
    tmux = build_mock_tmux_adapter
    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :session_input, args: [ "dev", "hello world" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, tmux.send_keys_calls.size
    assert_equal "dev", tmux.send_keys_calls.first[:target]
    assert_equal "hello world", tmux.send_keys_calls.first[:text]
    assert_includes posted.first[:message], "Sent to"
  end

  test "!spawn creates session and saves to store" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.session_exists_result = false
    tmux_store = build_tmux_store
    executor = build_executor(posted: posted, tmux_store: tmux_store, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :spawn, args: [ "fix tests", " --name my-fix --dir /tmp" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, tmux.created_sessions.size
    assert_equal "my-fix", tmux.created_sessions.first[:name]
    assert_equal "/tmp", tmux.created_sessions.first[:working_dir]
    assert_includes tmux.created_sessions.first[:command], "claude"
    assert_equal "claude fix\\ tests", tmux.created_sessions.first[:command]
    assert_equal 1, tmux_store[:saved].size
    assert_includes posted.first[:message], "Spawned"
  end

  test "!spawn rejects duplicate session name" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.session_exists_result = true
    executor = build_executor(posted: posted, tmux_adapter: tmux)

    command = Earl::CommandParser::ParsedCommand.new(name: :spawn, args: [ "fix tests", " --name existing" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "already exists"
  end

  test "!spawn rejects invalid directory" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :spawn, args: [ "fix tests", " --dir /nonexistent/path/12345" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "not found"
  end

  test "!restart replies and calls runner.request_restart" do
    posted = []
    mock_runner = Object.new
    restarted = false
    mock_runner.define_singleton_method(:request_restart) { restarted = true }

    executor = build_executor(posted: posted, runner: mock_runner)

    command = Earl::CommandParser::ParsedCommand.new(name: :restart, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, posted.size
    assert_includes posted.first[:message], "Restarting"
    assert restarted, "Expected runner.request_restart to be called"
  end

  test "!restart handles nil runner gracefully" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :restart, args: [])
    assert_nothing_raised do
      executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")
    end

    assert_equal 1, posted.size
    assert_includes posted.first[:message], "Restarting"
  end

  test "!update replies and calls runner.request_update" do
    posted = []
    mock_runner = Object.new
    updated = false
    mock_runner.define_singleton_method(:request_update) { updated = true }

    executor = build_executor(posted: posted, runner: mock_runner)

    command = Earl::CommandParser::ParsedCommand.new(name: :update, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, posted.size
    assert_includes posted.first[:message], "Updating"
    assert updated, "Expected runner.request_update to be called"
  end

  test "!restart saves restart context to disk" do
    posted = []
    mock_runner = Object.new
    mock_runner.define_singleton_method(:request_restart) { nil }

    executor = build_executor(posted: posted, runner: mock_runner)

    command = Earl::CommandParser::ParsedCommand.new(name: :restart, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    path = File.join(Earl.config_root, "restart_context.json")
    assert File.exist?(path), "Expected restart_context.json to be written"

    data = JSON.parse(File.read(path))
    assert_equal "channel-1", data["channel_id"]
    assert_equal "thread-1", data["thread_id"]
    assert_equal "restart", data["command"]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "!help includes restart command" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :help, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "!restart"
  end

  # -- New tests: empty prompt, invalid name, shell-safe prompt ---------------

  test "!spawn rejects empty prompt" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :spawn, args: [ "", "" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Usage"
  end

  test "!spawn rejects nil prompt" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :spawn, args: [ nil, "" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Usage"
  end

  test "!spawn rejects whitespace-only prompt" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :spawn, args: [ "   ", "" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Usage"
  end

  test "!spawn rejects name containing dot" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :spawn, args: [ "fix tests", " --name bad.name" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Invalid session name"
    assert_includes posted.first[:message], "bad.name"
  end

  test "!spawn rejects name containing colon" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :spawn, args: [ "fix tests", " --name bad:name" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "Invalid session name"
    assert_includes posted.first[:message], "bad:name"
  end

  test "!spawn shell-escapes prompt to prevent injection" do
    posted = []
    tmux = build_mock_tmux_adapter
    tmux.session_exists_result = false
    tmux_store = build_tmux_store
    executor = build_executor(posted: posted, tmux_store: tmux_store, tmux_adapter: tmux)

    malicious_prompt = 'hello"; rm -rf /'
    command = Earl::CommandParser::ParsedCommand.new(name: :spawn, args: [ malicious_prompt, " --name safe-test --dir /tmp" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal 1, tmux.created_sessions.size
    # The command should be properly escaped, not containing unescaped quotes
    cmd = tmux.created_sessions.first[:command]
    assert_includes cmd, "claude"
    assert_not_includes cmd, '";'
    assert_equal "claude hello\\\"\\;\\ rm\\ -rf\\ /", cmd
  end

  private

  # -- Mock tmux adapter for DI (no global singleton mutation) ---------------

  class MockTmuxAdapter
    attr_accessor :available_result, :session_exists_result, :capture_pane_result,
                  :capture_pane_error, :list_sessions_result, :list_panes_result,
                  :send_keys_error, :pane_child_commands_result,
                  :list_all_panes_result, :claude_on_tty_results
    attr_reader :send_keys_calls, :send_keys_raw_calls, :created_sessions, :killed_sessions

    def initialize
      @available_result = true
      @session_exists_result = true
      @capture_pane_result = ""
      @capture_pane_error = nil
      @list_sessions_result = []
      @list_panes_result = []
      @send_keys_error = nil
      @send_keys_calls = []
      @send_keys_raw_calls = []
      @created_sessions = []
      @killed_sessions = []
      @pane_child_commands_result = []
      @list_all_panes_result = []
      @claude_on_tty_results = {}
    end

    def available?
      @available_result
    end

    def session_exists?(_name)
      @session_exists_result
    end

    def capture_pane(_name, **_opts)
      raise @capture_pane_error if @capture_pane_error

      @capture_pane_result
    end

    def list_sessions
      @list_sessions_result
    end

    def list_panes(_session)
      @list_panes_result
    end

    def send_keys(target, text)
      raise @send_keys_error if @send_keys_error

      @send_keys_calls << { target: target, text: text }
    end

    def send_keys_raw(target, key)
      @send_keys_raw_calls << { target: target, key: key }
    end

    def create_session(name:, command: nil, working_dir: nil)
      @created_sessions << { name: name, command: command, working_dir: working_dir }
    end

    def kill_session(name)
      @killed_sessions << name
    end

    def pane_child_commands(_pid)
      @pane_child_commands_result
    end

    def list_all_panes
      @list_all_panes_result
    end

    def claude_on_tty?(tty)
      @claude_on_tty_results.fetch(tty, false)
    end
  end

  def build_mock_tmux_adapter
    MockTmuxAdapter.new
  end

  def build_executor(posted: [], session: nil, stopped: [], heartbeat_scheduler: :not_set, tmux_store: nil, tmux_adapter: nil, runner: nil)
    config = Earl::Config.new

    mock_manager = Object.new
    mock_manager.define_singleton_method(:get) { |_id| session }
    sess = session
    mock_manager.define_singleton_method(:claude_session_id_for) { |_id| sess&.respond_to?(:session_id) ? sess.session_id : nil }
    mock_manager.define_singleton_method(:persisted_session_for) { |_id| nil }
    stoppd = stopped
    mock_manager.define_singleton_method(:stop_session) { |thread_id| stoppd << thread_id }

    pstd = posted
    mock_mm = Object.new
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      pstd << { channel_id: channel_id, message: message, root_id: root_id }
      { "id" => "reply-1" }
    end

    opts = {
      session_manager: mock_manager,
      mattermost: mock_mm,
      config: config
    }
    opts[:heartbeat_scheduler] = heartbeat_scheduler unless heartbeat_scheduler == :not_set
    opts[:tmux_store] = tmux_store[:store] if tmux_store
    opts[:tmux_adapter] = tmux_adapter if tmux_adapter
    opts[:runner] = runner if runner

    Earl::CommandExecutor.new(**opts)
  end

  def build_tmux_store
    tracker = { saved: [], deleted: [] }
    store = Object.new
    svd = tracker[:saved]
    dlt = tracker[:deleted]
    store.define_singleton_method(:save) { |info| svd << info }
    store.define_singleton_method(:delete) { |name| dlt << name }
    tracker[:store] = store
    tracker
  end
end
