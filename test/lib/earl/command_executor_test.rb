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
    Process.define_singleton_method(:kill) do |signal, pid|
      killed << { signal: signal, pid: pid }
    end

    command = Earl::CommandParser::ParsedCommand.new(name: :escape, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal [ { signal: "INT", pid: 99999 } ], killed
    assert_includes posted.first[:message], "SIGINT"
  ensure
    # Restore original Process.kill
    class << Process
      remove_method :kill
    end
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
    Process.define_singleton_method(:kill) do |signal, pid|
      killed << { signal: signal, pid: pid }
    end

    command = Earl::CommandParser::ParsedCommand.new(name: :kill, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_equal [ { signal: "KILL", pid: 99999 } ], killed
    assert_equal [ "thread-1" ], stopped
    assert_includes posted.first[:message], "force killed"
  ensure
    class << Process
      remove_method :kill
    end
  end

  test "!kill reports no session when none active" do
    posted = []
    executor = build_executor(posted: posted, session: nil)

    command = Earl::CommandParser::ParsedCommand.new(name: :kill, args: [])
    executor.execute(command, thread_id: "thread-1", channel_id: "channel-1")

    assert_includes posted.first[:message], "No active session"
  end

  private

  def build_executor(posted: [], session: nil, stopped: [])
    config = Earl::Config.new

    mock_manager = Object.new
    mock_manager.define_singleton_method(:get) { |_id| session }
    stoppd = stopped
    mock_manager.define_singleton_method(:stop_session) { |thread_id| stoppd << thread_id }

    pstd = posted
    mock_mm = Object.new
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      pstd << { channel_id: channel_id, message: message, root_id: root_id }
      { "id" => "reply-1" }
    end

    Earl::CommandExecutor.new(
      session_manager: mock_manager,
      mattermost: mock_mm,
      config: config
    )
  end
end
