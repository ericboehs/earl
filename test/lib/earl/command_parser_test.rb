# frozen_string_literal: true

require "test_helper"

module Earl
  class CommandParserTest < Minitest::Test
    test "command? returns true for ! prefixed text" do
      assert Earl::CommandParser.command?("!help")
      assert Earl::CommandParser.command?("!stop")
      assert Earl::CommandParser.command?("  !help  ")
    end

    test "command? returns false for non-command text" do
      assert_not Earl::CommandParser.command?("hello")
      assert_not Earl::CommandParser.command?("not a command")
      assert_not Earl::CommandParser.command?("")
    end

    test "parse returns nil for non-command text" do
      assert_nil Earl::CommandParser.parse("hello")
      assert_nil Earl::CommandParser.parse("")
    end

    test "parse returns nil for unknown command" do
      assert_nil Earl::CommandParser.parse("!unknown")
      assert_nil Earl::CommandParser.parse("!foo bar")
    end

    test "parse recognizes !stop" do
      cmd = Earl::CommandParser.parse("!stop")
      assert_equal :stop, cmd.name
      assert_empty cmd.args
    end

    test "parse recognizes !escape" do
      cmd = Earl::CommandParser.parse("!escape")
      assert_equal :escape, cmd.name
    end

    test "parse recognizes !kill" do
      cmd = Earl::CommandParser.parse("!kill")
      assert_equal :kill, cmd.name
    end

    test "parse recognizes !help" do
      cmd = Earl::CommandParser.parse("!help")
      assert_equal :help, cmd.name
    end

    test "parse recognizes !cost as alias for !stats" do
      cmd = Earl::CommandParser.parse("!cost")
      assert_equal :stats, cmd.name
    end

    test "parse recognizes !stats" do
      cmd = Earl::CommandParser.parse("!stats")
      assert_equal :stats, cmd.name
    end

    test "parse recognizes !compact" do
      cmd = Earl::CommandParser.parse("!compact")
      assert_equal :compact, cmd.name
    end

    test "parse recognizes !cd with path" do
      cmd = Earl::CommandParser.parse("!cd /tmp/foo")
      assert_equal :cd, cmd.name
      assert_equal ["/tmp/foo"], cmd.args
    end

    test "parse recognizes !cd with relative path" do
      cmd = Earl::CommandParser.parse("!cd ~/Code/project")
      assert_equal :cd, cmd.name
      assert_equal ["~/Code/project"], cmd.args
    end

    test "parse recognizes !permissions" do
      cmd = Earl::CommandParser.parse("!permissions")
      assert_equal :permissions, cmd.name
      assert_empty cmd.args
    end

    test "parse recognizes !heartbeats" do
      cmd = Earl::CommandParser.parse("!heartbeats")
      assert_equal :heartbeats, cmd.name
      assert_empty cmd.args
    end

    test "parse recognizes !usage" do
      cmd = Earl::CommandParser.parse("!usage")
      assert_equal :usage, cmd.name
      assert_empty cmd.args
    end

    test "parse recognizes !context" do
      cmd = Earl::CommandParser.parse("!context")
      assert_equal :context, cmd.name
      assert_empty cmd.args
    end

    test "parse is case insensitive" do
      cmd = Earl::CommandParser.parse("!HELP")
      assert_equal :help, cmd.name

      cmd = Earl::CommandParser.parse("!Stop")
      assert_equal :stop, cmd.name
    end

    test "parse strips whitespace" do
      cmd = Earl::CommandParser.parse("  !help  ")
      assert_equal :help, cmd.name
    end

    # -- Tmux session commands --

    test "parse recognizes !sessions" do
      cmd = Earl::CommandParser.parse("!sessions")
      assert_equal :sessions, cmd.name
      assert_empty cmd.args
    end

    test "parse recognizes !session <name>" do
      cmd = Earl::CommandParser.parse("!session my-session")
      assert_equal :session_show, cmd.name
      assert_equal ["my-session"], cmd.args
    end

    test "parse recognizes !session <name> status" do
      cmd = Earl::CommandParser.parse("!session my-session status")
      assert_equal :session_status, cmd.name
      assert_equal ["my-session"], cmd.args
    end

    test "parse recognizes !session <name> kill" do
      cmd = Earl::CommandParser.parse("!session my-session kill")
      assert_equal :session_kill, cmd.name
      assert_equal ["my-session"], cmd.args
    end

    test "parse recognizes !session <name> nudge" do
      cmd = Earl::CommandParser.parse("!session my-session nudge")
      assert_equal :session_nudge, cmd.name
      assert_equal ["my-session"], cmd.args
    end

    test "parse recognizes !session <name> with double-quoted input" do
      cmd = Earl::CommandParser.parse('!session my-session "hello world"')
      assert_equal :session_input, cmd.name
      assert_equal ["my-session", "hello world"], cmd.args
    end

    test "parse recognizes !session <name> with single-quoted input" do
      cmd = Earl::CommandParser.parse("!session my-session 'hello world'")
      assert_equal :session_input, cmd.name
      assert_equal ["my-session", "hello world"], cmd.args
    end

    test "parse recognizes !spawn with prompt" do
      cmd = Earl::CommandParser.parse('!spawn "fix the tests"')
      assert_equal :spawn, cmd.name
      assert_equal ["fix the tests", ""], cmd.args
    end

    test "parse recognizes !spawn with prompt and flags" do
      cmd = Earl::CommandParser.parse('!spawn "fix the tests" --name my-fix --dir /tmp')
      assert_equal :spawn, cmd.name
      assert_equal ["fix the tests", " --name my-fix --dir /tmp"], cmd.args
    end

    test "session status is matched before session show" do
      # Ensures ordering: status, kill, nudge come before catch-all session_show
      cmd_status = Earl::CommandParser.parse("!session foo status")
      cmd_show = Earl::CommandParser.parse("!session foo")

      assert_equal :session_status, cmd_status.name
      assert_equal :session_show, cmd_show.name
    end

    test "session kill is matched before session show" do
      cmd = Earl::CommandParser.parse("!session foo kill")
      assert_equal :session_kill, cmd.name
    end

    test "session nudge is matched before session show" do
      cmd = Earl::CommandParser.parse("!session foo nudge")
      assert_equal :session_nudge, cmd.name
    end

    test "parse recognizes !session <name> approve" do
      cmd = Earl::CommandParser.parse("!session code:4.0 approve")
      assert_equal :session_approve, cmd.name
      assert_equal ["code:4.0"], cmd.args
    end

    test "parse recognizes !session <name> deny" do
      cmd = Earl::CommandParser.parse("!session code:4.0 deny")
      assert_equal :session_deny, cmd.name
      assert_equal ["code:4.0"], cmd.args
    end

    test "parse recognizes !update" do
      cmd = Earl::CommandParser.parse("!update")
      assert_equal :update, cmd.name
      assert_empty cmd.args
    end

    test "parse recognizes !restart" do
      cmd = Earl::CommandParser.parse("!restart")
      assert_equal :restart, cmd.name
      assert_empty cmd.args
    end

    test "session commands are case insensitive" do
      cmd = Earl::CommandParser.parse("!Sessions")
      assert_equal :sessions, cmd.name

      cmd = Earl::CommandParser.parse("!Session foo STATUS")
      assert_equal :session_status, cmd.name

      cmd = Earl::CommandParser.parse("!SPAWN \"hello\"")
      assert_equal :spawn, cmd.name
    end
  end
end
