# frozen_string_literal: true

require "test_helper"

module Earl
  class TmuxTest < Minitest::Test
    setup do
      Earl.logger = Logger.new(File::NULL)
      @original_capture2e = Open3.method(:capture2e)
    end

    teardown do
      Earl.logger = nil
      restore_open3
    end

    test "available? returns true when tmux is installed" do
      stub_open3("", true)
      assert Earl::Tmux.available?
    end

    test "available? returns false when tmux is not installed" do
      stub_open3("", false)
      assert_not Earl::Tmux.available?
    end

    test "list_sessions parses format string" do
      output = "dev|||1|||1739440800\nwork|||0|||1739437200\n"
      stub_open3(output, true)

      sessions = Earl::Tmux.list_sessions
      assert_equal 2, sessions.size

      assert_equal "dev", sessions[0][:name]
      assert sessions[0][:attached]
      assert_match(/2025/, sessions[0][:created_at])

      assert_equal "work", sessions[1][:name]
      assert_not sessions[1][:attached]
    end

    test "list_sessions returns empty array when no server running" do
      stub_open3("no server running", false)
      assert_equal [], Earl::Tmux.list_sessions
    end

    test "list_sessions returns empty array when no sessions" do
      stub_open3("no sessions", false)
      assert_equal [], Earl::Tmux.list_sessions
    end

    test "list_panes parses format string" do
      output = "0|||claude|||/home/user/project|||12345\n1|||bash|||/home/user|||12346\n"
      stub_open3(output, true)

      panes = Earl::Tmux.list_panes("dev")
      assert_equal 2, panes.size

      assert_equal 0, panes[0][:index]
      assert_equal "claude", panes[0][:command]
      assert_equal "/home/user/project", panes[0][:path]
      assert_equal 12_345, panes[0][:pid]
    end

    test "list_panes raises NotFound for missing session" do
      stub_open3("can't find session: missing", false)
      assert_raises(Earl::Tmux::NotFound) { Earl::Tmux.list_panes("missing") }
    end

    test "capture_pane returns output string" do
      output = "line1\nline2\nline3\n"
      stub_open3(output, true)
      assert_equal output, Earl::Tmux.capture_pane("dev")
    end

    test "capture_pane raises NotFound for missing target" do
      stub_open3("can't find pane: missing", false)
      assert_raises(Earl::Tmux::NotFound) { Earl::Tmux.capture_pane("missing") }
    end

    test "send_keys calls execute twice with sleep" do
      calls = []
      stub_open3_with_tracking(calls)

      # Override sleep to not actually wait
      stub_singleton(Earl::Tmux, :sleep) { |_| nil }
      Earl::Tmux.send_keys("dev", "hello")

      assert_equal 2, calls.size
      assert_includes calls[0], "-l"
      assert_includes calls[0], "hello"
      assert_includes calls[1], "Enter"
    ensure
      # Remove our override so module_function's sleep is used again
      Earl::Tmux.singleton_class.remove_method(:sleep) if Earl::Tmux.singleton_class.method_defined?(:sleep, false)
    end

    test "send_keys_raw sends key without -l flag" do
      calls = []
      stub_open3_with_tracking(calls)

      Earl::Tmux.send_keys_raw("dev", "C-c")

      assert_equal 1, calls.size
      assert_includes calls[0], "C-c"
      assert_not_includes calls[0], "-l"
    end

    test "create_session builds correct command with all options" do
      calls = []
      stub_open3_with_tracking(calls)

      Earl::Tmux.create_session(name: "test", command: "claude", working_dir: "/tmp")

      assert_equal 1, calls.size
      cmd = calls[0]
      assert_includes cmd, "new-session"
      assert_includes cmd, "-s"
      assert_includes cmd, "test"
      assert_includes cmd, "-c"
      assert_includes cmd, "/tmp"
      assert_includes cmd, "claude"
    end

    test "create_session works without optional params" do
      calls = []
      stub_open3_with_tracking(calls)

      Earl::Tmux.create_session(name: "test")

      cmd = calls[0]
      assert_includes cmd, "test"
      assert_not_includes cmd, "-c"
    end

    test "kill_session sends kill command" do
      calls = []
      stub_open3_with_tracking(calls)

      Earl::Tmux.kill_session("test")

      assert_includes calls[0], "kill-session"
      assert_includes calls[0], "test"
    end

    test "kill_session raises NotFound for missing session" do
      stub_open3("can't find session: test", false)
      assert_raises(Earl::Tmux::NotFound) { Earl::Tmux.kill_session("missing") }
    end

    test "session_exists? returns true when session exists" do
      stub_open3("", true)
      assert Earl::Tmux.session_exists?("dev")
    end

    test "session_exists? returns false when session does not exist" do
      stub_open3("can't find session", false)
      assert_not Earl::Tmux.session_exists?("missing")
    end

    test "wait_for_text returns output when pattern matches immediately" do
      stub_open3("Ready ❯ ", true)
      stub_singleton(Earl::Tmux, :sleep) { |_| nil }

      result = Earl::Tmux.wait_for_text("dev", /❯/, timeout: 1, interval: 0.01)
      assert_equal "Ready ❯ ", result
    ensure
      Earl::Tmux.singleton_class.remove_method(:sleep) if Earl::Tmux.singleton_class.method_defined?(:sleep, false)
    end

    test "wait_for_text returns nil on timeout" do
      stub_open3("still loading...", true)

      result = Earl::Tmux.wait_for_text("dev", /❯/, timeout: 0.05, interval: 0.01)
      assert_nil result
    end

    test "wait_for_text accepts string patterns" do
      stub_open3("found the needle here", true)
      stub_singleton(Earl::Tmux, :sleep) { |_| nil }

      result = Earl::Tmux.wait_for_text("dev", "needle", timeout: 1, interval: 0.01)
      assert_match(/needle/, result)
    ensure
      Earl::Tmux.singleton_class.remove_method(:sleep) if Earl::Tmux.singleton_class.method_defined?(:sleep, false)
    end

    test "list_sessions skips malformed lines" do
      output = "dev|||1|||1739440800\nbadline\n"
      stub_open3(output, true)

      sessions = Earl::Tmux.list_sessions
      assert_equal 1, sessions.size
      assert_equal "dev", sessions[0][:name]
    end

    test "list_sessions re-raises non-server errors" do
      stub_open3("some other error", false)
      assert_raises(Earl::Tmux::Error) { Earl::Tmux.list_sessions }
    end

    test "list_panes skips malformed lines" do
      output = "0|||claude|||/home|||12345\nbadline\n"
      stub_open3(output, true)

      panes = Earl::Tmux.list_panes("dev")
      assert_equal 1, panes.size
    end

    test "list_panes re-raises non-find errors" do
      stub_open3("some other error", false)
      assert_raises(Earl::Tmux::Error) { Earl::Tmux.list_panes("dev") }
    end

    test "capture_pane re-raises non-find errors" do
      stub_open3("some other error", false)
      assert_raises(Earl::Tmux::Error) { Earl::Tmux.capture_pane("dev") }
    end

    test "kill_session re-raises non-find errors" do
      stub_open3("some other error", false)
      assert_raises(Earl::Tmux::Error) { Earl::Tmux.kill_session("dev") }
    end

    test "pane_child_commands returns process names for PID and its children" do
      ps_output = "/Users/me/.local/bin/claude\n"
      children_output = " 100  1 launchd\n 200 99 -zsh\n 300 99 /Users/me/.local/bin/claude\n 400 50 unrelated\n"

      call_count = 0
      status = mock_status(true)
      stub_singleton(Open3, :capture2e) do |*_args|
        call_count += 1
        if call_count == 1
          [ps_output, status]
        else
          [children_output, status]
        end
      end

      result = Earl::Tmux.pane_child_commands(99)
      assert_includes result, "/Users/me/.local/bin/claude"
      assert_includes result, "-zsh"
      assert_not_includes result, "unrelated"
    end

    test "pane_child_commands returns empty array on error" do
      stub_singleton(Open3, :capture2e) { |*_args| raise Errno::ENOENT, "ps not found" }
      assert_equal [], Earl::Tmux.pane_child_commands(99_999)
    end

    test "list_all_panes returns panes across all sessions" do
      output = "code|||1|||0|||2.1.42|||/home/user/project|||12345|||/dev/ttys001\n" \
               "chat|||1|||0|||weechat|||/home/user|||12346|||/dev/ttys002\n"
      stub_open3(output, true)

      panes = Earl::Tmux.list_all_panes
      assert_equal 2, panes.size

      assert_equal "code:1.0", panes[0][:target]
      assert_equal "code", panes[0][:session]
      assert_equal 1, panes[0][:window]
      assert_equal "2.1.42", panes[0][:command]
      assert_equal "/home/user/project", panes[0][:path]
      assert_equal 12_345, panes[0][:pid]
      assert_equal "/dev/ttys001", panes[0][:tty]

      assert_equal "chat:1.0", panes[1][:target]
      assert_equal "weechat", panes[1][:command]
    end

    test "list_all_panes returns empty array when no server running" do
      stub_open3("no server running", false)
      assert_equal [], Earl::Tmux.list_all_panes
    end

    test "list_all_panes skips malformed lines" do
      output = "code|||1|||0|||claude|||/tmp|||123|||/dev/ttys001\nbadline\n"
      stub_open3(output, true)

      panes = Earl::Tmux.list_all_panes
      assert_equal 1, panes.size
    end

    test "claude_on_tty? returns true when claude process on tty" do
      output = "-zsh\n/Users/me/.local/bin/claude\n"
      stub_open3(output, true)
      assert Earl::Tmux.claude_on_tty?("/dev/ttys001")
    end

    test "claude_on_tty? returns false when no claude on tty" do
      output = "-zsh\nweechat\n"
      stub_open3(output, true)
      assert_not Earl::Tmux.claude_on_tty?("/dev/ttys001")
    end

    test "claude_on_tty? returns false on error" do
      stub_singleton(Open3, :capture2e) { |*_args| raise Errno::ENOENT, "ps not found" }
      assert_not Earl::Tmux.claude_on_tty?("/dev/ttys999")
    end

    test "list_all_panes re-raises non-server errors" do
      stub_open3("some other error", false)
      assert_raises(Earl::Tmux::Error) { Earl::Tmux.list_all_panes }
    end

    # -- create_window tests (covers build_create_window_args branches) --------

    test "create_window with all options" do
      calls = []
      stub_open3_with_tracking(calls)

      Earl::Tmux.create_window(session: "dev", name: "logs", working_dir: "/tmp", command: "tail -f log")

      cmd = calls[0]
      assert_includes cmd, "new-window"
      assert_includes cmd, "-t"
      assert_includes cmd, "dev"
      assert_includes cmd, "-n"
      assert_includes cmd, "logs"
      assert_includes cmd, "-c"
      assert_includes cmd, "/tmp"
      assert_includes cmd, "tail -f log"
    end

    test "create_window without optional name" do
      calls = []
      stub_open3_with_tracking(calls)

      Earl::Tmux.create_window(session: "dev", working_dir: "/tmp", command: "bash")

      cmd = calls[0]
      assert_includes cmd, "new-window"
      assert_includes cmd, "-t"
      assert_includes cmd, "dev"
      assert_not_includes cmd, "-n"
      assert_includes cmd, "-c"
      assert_includes cmd, "/tmp"
    end

    test "create_window without optional working_dir" do
      calls = []
      stub_open3_with_tracking(calls)

      Earl::Tmux.create_window(session: "dev", name: "shell")

      cmd = calls[0]
      assert_includes cmd, "-n"
      assert_includes cmd, "shell"
      assert_not_includes cmd, "-c"
    end

    test "create_window without optional command" do
      calls = []
      stub_open3_with_tracking(calls)

      Earl::Tmux.create_window(session: "dev")

      cmd = calls[0]
      assert_includes cmd, "new-window"
      assert_includes cmd, "-t"
      assert_includes cmd, "dev"
      assert_not_includes cmd, "-n"
      assert_not_includes cmd, "-c"
      # No command at end — only session args
      assert_equal 4, cmd.flatten.size
    end

    test "parse_process_entries skips lines with fewer than 3 fields" do
      output = " 100  1 /usr/bin/zsh\n12345\n\n 200  1 /usr/bin/bash\n"

      entries = Earl::Tmux.send(:parse_process_entries, output)
      assert_equal 2, entries.size
      assert_equal "/usr/bin/zsh", entries[0][:comm]
      assert_equal "/usr/bin/bash", entries[1][:comm]
    end

    test "parse_process_entries returns empty array for blank output" do
      entries = Earl::Tmux.send(:parse_process_entries, "")
      assert_equal [], entries
    end

    private

    def mock_status(success)
      status = Object.new
      stub_singleton(status, :success?) { success }
      status
    end

    def stub_open3(output, success)
      status = mock_status(success)
      stub_singleton(Open3, :capture2e) { |*_args| [output, status] }
    end

    def stub_open3_with_tracking(calls)
      status = mock_status(true)
      stub_singleton(Open3, :capture2e) do |*args|
        calls << args
        ["", status]
      end
    end

    def restore_open3
      original = @original_capture2e
      stub_singleton(Open3, :capture2e) { |*args| original.call(*args) }
    end
  end
end
