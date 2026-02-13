require "test_helper"

class Earl::CommandParserTest < ActiveSupport::TestCase
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
    assert_equal [ "/tmp/foo" ], cmd.args
  end

  test "parse recognizes !cd with relative path" do
    cmd = Earl::CommandParser.parse("!cd ~/Code/project")
    assert_equal :cd, cmd.name
    assert_equal [ "~/Code/project" ], cmd.args
  end

  test "parse recognizes !permissions auto" do
    cmd = Earl::CommandParser.parse("!permissions auto")
    assert_equal :permissions, cmd.name
    assert_equal [ "auto" ], cmd.args
  end

  test "parse recognizes !permissions interactive" do
    cmd = Earl::CommandParser.parse("!permissions interactive")
    assert_equal :permissions, cmd.name
    assert_equal [ "interactive" ], cmd.args
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
end
