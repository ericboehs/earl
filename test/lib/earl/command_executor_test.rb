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

  test "!permissions sets mode" do
    posted = []
    executor = build_executor(posted: posted)

    command = Earl::CommandParser::ParsedCommand.new(name: :permissions, args: [ "auto" ])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal :auto, executor.permission_mode_for("thread-1")
  end

  test "!compact sends /compact to session" do
    sent_messages = []
    mock_session = Object.new
    mock_session.define_singleton_method(:send_message) { |text| sent_messages << text }

    executor = build_executor(session: mock_session)

    command = Earl::CommandParser::ParsedCommand.new(name: :compact, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal [ "/compact" ], sent_messages
  end

  test "permission_mode_for defaults to interactive" do
    executor = build_executor
    assert_equal :interactive, executor.permission_mode_for("thread-1")
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

  test "!compact does nothing when no session" do
    executor = build_executor(session: nil)

    command = Earl::CommandParser::ParsedCommand.new(name: :compact, args: [])
    # Should not raise — session&.send_message with nil session
    assert_nothing_raised do
      executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")
    end
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
    assert_includes result, "**Session:** 80% used"
    assert_includes result, "**Week:** 45% used"
    assert_includes result, "**Extra:** 30% used ($6.00 / $20.00)"
  end

  test "format_usage handles missing sections gracefully" do
    executor = build_executor
    data = { "session" => { "percent_used" => nil } }

    result = executor.send(:format_usage, data)
    assert_includes result, "Claude Pro Usage"
    assert_not_includes result, "Session"
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
    executor.instance_variable_get(:@session_manager)
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

  private

  def build_executor(posted: [], session: nil, stopped: [], heartbeat_scheduler: :not_set)
    config = Earl::Config.new

    mock_manager = Object.new
    mock_manager.define_singleton_method(:get) { |_id| session }
    sess = session
    mock_manager.define_singleton_method(:claude_session_id_for) { |_id| sess&.respond_to?(:session_id) ? sess.session_id : nil }
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

    Earl::CommandExecutor.new(**opts)
  end
end
