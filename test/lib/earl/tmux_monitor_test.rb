# frozen_string_literal: true

require "test_helper"

module Earl
  class TmuxMonitorTest < Minitest::Test
    setup do
      Earl.logger = Logger.new(File::NULL)
      @tmp_dir = File.join(Dir.tmpdir, "earl-monitor-test-#{SecureRandom.hex(4)}")
      FileUtils.mkdir_p(@tmp_dir)
      @store_path = File.join(@tmp_dir, "tmux_sessions.json")
      @tmux_store = Earl::TmuxSessionStore.new(path: @store_path)
      @mattermost = build_mock_mattermost
      @tmux_adapter = build_mock_tmux_adapter

      # Speed up poll_loop sleep from 45s to near-instant for tests
      @original_poll_interval = ENV.fetch("EARL_TMUX_POLL_INTERVAL", nil)
      ENV["EARL_TMUX_POLL_INTERVAL"] = "0"

      @monitor = Earl::TmuxMonitor.new(
        mattermost: @mattermost, tmux_store: @tmux_store,
        tmux_adapter: @tmux_adapter
      )
    end

    teardown do
      Earl.logger = nil
      if @original_poll_interval
        ENV["EARL_TMUX_POLL_INTERVAL"] = @original_poll_interval
      else
        ENV.delete("EARL_TMUX_POLL_INTERVAL")
      end
      FileUtils.rm_rf(@tmp_dir)
    end

    # -- detect_state tests ------------------------------------------------------

    test "detect_state returns :completed when shell prompt in last lines" do
      output = "some output\nmore output\nuser@host:~$ "
      assert_equal :completed, call_detect_state(output)
    end

    test "detect_state detects shell prompt with ❯" do
      output = "some output\nmore output\n❯ "
      assert_equal :completed, call_detect_state(output)
    end

    test "detect_state detects shell prompt with # (root)" do
      output = "some output\nmore output\nroot@host:~# "
      assert_equal :completed, call_detect_state(output)
    end

    test "detect_state detects shell prompt with %" do
      output = "some output\nmore output\nhost% "
      assert_equal :completed, call_detect_state(output)
    end

    test "detect_state does not false-positive on dollar amounts like $0.05" do
      output = "Processing...\nCost: $0.05\nStill running\n"
      assert_equal :running, call_detect_state(output)
    end

    test "detect_state detects shell prompt with $ followed by space" do
      output = "some output\nmore output\nuser@host:~$ "
      assert_equal :completed, call_detect_state(output)
    end

    test "detect_state returns :asking_question for numbered options" do
      output = "Which file do you want to edit?\n  1. foo.rb\n  2. bar.rb\n"
      assert_equal :asking_question, call_detect_state(output)
    end

    test "detect_state returns :requesting_permission for Allow prompt" do
      output = "Tool: Write\nDo you want to allow this action?\n"
      assert_equal :requesting_permission, call_detect_state(output)
    end

    test "detect_state returns :requesting_permission for Deny keyword" do
      output = "Allow or Deny this tool use:\nBash: rm -rf /tmp/foo\n"
      assert_equal :requesting_permission, call_detect_state(output)
    end

    test "detect_state returns :errored for Error: pattern" do
      output = "Running task...\nError: something went wrong\n"
      assert_equal :errored, call_detect_state(output)
    end

    test "detect_state returns :errored for FAILED pattern" do
      output = "Test run FAILED\n3 tests, 1 failure\n"
      assert_equal :errored, call_detect_state(output)
    end

    test "detect_state returns :errored for Traceback pattern" do
      output = "Traceback (most recent call last):\n  File \"test.py\"\n"
      assert_equal :errored, call_detect_state(output)
    end

    test "detect_state returns :running for normal output" do
      output = "Processing files...\nDone with step 1\nStarting step 2\n"
      assert_equal :running, call_detect_state(output)
    end

    test "detect_state returns :running for empty output" do
      assert_equal :running, call_detect_state("")
    end

    test "detect_state ignores error patterns beyond last 15 lines" do
      old_lines = (1..20).map { |i| "Line #{i}: doing stuff\n" }.join
      error_in_old_output = "Error: old problem that was already resolved\n#{old_lines}"
      # The Error: line is line 1, but the last 15 lines are lines 7-21 (no error)
      assert_equal :running, call_detect_state(error_in_old_output)
    end

    test "detect_state returns :stalled after threshold consecutive identical outputs" do
      output = "Stuck on something...\nWaiting...\n"
      name = "test-session"

      # First call stores the hash
      assert_equal :running, call_detect_state(output, name)

      # Calls 2 through threshold-1 increment but don't trigger
      (Earl::TmuxMonitor::DEFAULT_STALL_THRESHOLD - 2).times do
        assert_equal :running, call_detect_state(output, name)
      end

      # The threshold-th call should trigger stalled
      assert_equal :stalled, call_detect_state(output, name)
    end

    test "detect_state resets stall counter when output changes" do
      name = "test-session"

      # Build up stall count
      3.times { call_detect_state("same output\n", name) }

      # Different output resets counter
      assert_equal :running, call_detect_state("different output\n", name)

      # Need full threshold again
      assert_equal :running, call_detect_state("different output\n", name)
    end

    # -- state_changed? tests ----------------------------------------------------

    test "state_changed? returns true for new session" do
      assert call_state_changed?("new-session", :running)
    end

    test "state_changed? returns true when state differs" do
      set_last_state("session", :running)
      assert call_state_changed?("session", :errored)
    end

    test "state_changed? returns false when state is the same" do
      set_last_state("session", :running)
      assert_not call_state_changed?("session", :running)
    end

    test "state_changed? re-triggers for repeated asking_question state when no pending interaction" do
      set_last_state("session", :asking_question)
      assert call_state_changed?("session", :asking_question)
    end

    test "state_changed? re-triggers for repeated requesting_permission state when no pending interaction" do
      set_last_state("session", :requesting_permission)
      assert call_state_changed?("session", :requesting_permission)
    end

    test "state_changed? does not re-trigger asking_question when pending interaction exists" do
      set_last_state("session", :asking_question)
      add_pending_interaction("post-123", session_name: "session", type: :question, options: ["A"])
      assert_not call_state_changed?("session", :asking_question)
    end

    test "state_changed? does not re-trigger requesting_permission when pending interaction exists" do
      set_last_state("session", :requesting_permission)
      add_pending_interaction("post-456", session_name: "session", type: :permission)
      assert_not call_state_changed?("session", :requesting_permission)
    end

    # -- parse_question tests ----------------------------------------------------

    test "parse_question extracts question and options" do
      output = <<~OUTPUT
        Some context here
        Which option do you prefer?
        1. Option A
        2. Option B
        3. Option C
      OUTPUT

      result = call_parse_question(output)
      assert_equal "Which option do you prefer?", result[:text]
      assert_equal ["Option A", "Option B", "Option C"], result[:options]
    end

    test "parse_question handles parenthesized numbers" do
      output = <<~OUTPUT
        What do you want?
        1) First choice
        2) Second choice
      OUTPUT

      result = call_parse_question(output)
      assert_equal ["First choice", "Second choice"], result[:options]
    end

    test "parse_question limits to 4 options" do
      output = <<~OUTPUT
        Pick one?
        1. A
        2. B
        3. C
        4. D
        5. E
      OUTPUT

      result = call_parse_question(output)
      assert_equal 4, result[:options].size
    end

    test "parse_question returns nil when no question mark" do
      output = "No question here\n1. Option A\n2. Option B\n"
      assert_nil call_parse_question(output)
    end

    test "parse_question returns nil when no numbered options" do
      output = "Is this a question?\nJust some text after\n"
      assert_nil call_parse_question(output)
    end

    test "parse_question returns nil for all-empty input" do
      assert_nil call_parse_question("")
      assert_nil call_parse_question("\n\n\n")
    end

    # -- handle_reaction tests ---------------------------------------------------

    test "handle_reaction returns nil for unknown post_id" do
      assert_nil @monitor.handle_reaction(post_id: "unknown", emoji_name: "one")
    end

    test "handle_reaction handles question reaction with valid emoji" do
      seed_pending_interaction("post-1", type: :question, options: %w[foo bar baz])

      result = @monitor.handle_reaction(post_id: "post-1", emoji_name: "two")
      assert_equal true, result

      # Should have sent "2" (1-indexed) to tmux
      assert_equal 1, @tmux_send_keys_calls.size
      assert_equal "test-session", @tmux_send_keys_calls[0][:target]
      assert_equal "2", @tmux_send_keys_calls[0][:text]
    end

    test "handle_reaction cleans up pending interaction after question answer" do
      seed_pending_interaction("post-1", type: :question, options: %w[foo bar])

      @monitor.handle_reaction(post_id: "post-1", emoji_name: "one")

      # Second call should return nil (interaction removed)
      assert_nil @monitor.handle_reaction(post_id: "post-1", emoji_name: "one")
    end

    test "handle_reaction returns nil for invalid emoji on question" do
      seed_pending_interaction("post-1", type: :question, options: %w[foo bar])
      assert_nil @monitor.handle_reaction(post_id: "post-1", emoji_name: "invalid")
    end

    test "handle_reaction returns nil for out-of-range emoji on question" do
      seed_pending_interaction("post-1", type: :question, options: %w[foo])

      # "two" maps to index 1, but only 1 option exists
      assert_nil @monitor.handle_reaction(post_id: "post-1", emoji_name: "two")
    end

    test "handle_reaction handles permission approval" do
      seed_pending_interaction("post-1", type: :permission)

      result = @monitor.handle_reaction(post_id: "post-1", emoji_name: "white_check_mark")
      assert_equal true, result
      assert_equal "y", @tmux_send_keys_calls[0][:text]
    end

    test "handle_reaction handles permission denial" do
      seed_pending_interaction("post-1", type: :permission)

      result = @monitor.handle_reaction(post_id: "post-1", emoji_name: "x")
      assert_equal true, result
      assert_equal "n", @tmux_send_keys_calls[0][:text]
    end

    test "handle_reaction returns nil for invalid permission emoji" do
      seed_pending_interaction("post-1", type: :permission)
      assert_nil @monitor.handle_reaction(post_id: "post-1", emoji_name: "thumbsup")
    end

    test "handle_reaction rescues Tmux::Error on question answer" do
      seed_pending_interaction("post-1", type: :question, options: %w[foo bar])
      configure_send_keys_error

      result = @monitor.handle_reaction(post_id: "post-1", emoji_name: "one")
      assert_nil result
    end

    test "handle_reaction rescues Tmux::Error on permission answer" do
      seed_pending_interaction("post-1", type: :permission)
      configure_send_keys_error

      result = @monitor.handle_reaction(post_id: "post-1", emoji_name: "white_check_mark")
      assert_nil result
    end

    # -- poll_sessions tests -----------------------------------------------------

    test "poll_sessions detects and alerts on dead sessions" do
      @tmux_store.save(build_info(name: "dead-session"))
      @tmux_adapter.session_exists_result = false

      call_poll_sessions

      # Should have posted tombstone alert
      assert_equal 1, @mattermost_posts.size
      assert_includes @mattermost_posts[0][:message], ":tombstone:"
      assert_includes @mattermost_posts[0][:message], "dead-session"

      # Should have cleaned up store
      assert_nil @tmux_store.get("dead-session")
    end

    test "poll_sessions cleans up pending interactions for dead sessions" do
      @tmux_store.save(build_info(name: "dead-session"))
      add_pending_interaction("post-old", session_name: "dead-session", type: :question, options: ["A"])
      add_pending_interaction("post-other", session_name: "other-session", type: :permission)
      @tmux_adapter.session_exists_result = false

      call_poll_sessions

      # Pending interactions for dead session should be cleaned up
      pending = poll_state.pending_interactions
      assert_nil pending["post-old"]
      # Unrelated session's pending interaction should remain
      assert_not_nil pending["post-other"]
    end

    test "poll_sessions detects state changes and posts alerts" do
      @tmux_store.save(build_info(name: "my-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Running task...\nError: something broke\n"

      call_poll_sessions

      assert_equal 1, @mattermost_posts.size
      assert_includes @mattermost_posts[0][:message], ":x:"
      assert_includes @mattermost_posts[0][:message], "my-session"
    end

    test "poll_sessions skips session when capture fails" do
      @tmux_store.save(build_info(name: "broken"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_error = Earl::Tmux::Error.new("capture failed")

      call_poll_sessions

      assert_empty @mattermost_posts
    end

    test "poll_sessions continues polling other sessions when one raises" do
      @tmux_store.save(build_info(name: "broken-session"))
      @tmux_store.save(build_info(name: "good-session"))
      # Build a custom adapter that errors on one session but works on another
      adapter = build_selective_error_adapter("broken-session", "Error: something broke\n")
      @monitor = Earl::TmuxMonitor.new(
        mattermost: @mattermost, tmux_store: @tmux_store,
        tmux_adapter: adapter
      )

      call_poll_sessions

      # Should have posted an alert for the good session (errored state)
      error_posts = @mattermost_posts.select { |p| p[:message].include?("good-session") }
      assert error_posts.size >= 1, "Expected alert for good-session even though broken-session raised"
    end

    test "poll_sessions posts completed alert for shell prompt" do
      @tmux_store.save(build_info(name: "done-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Task finished\nAll good\nuser@host:~$ "

      call_poll_sessions

      assert_equal 1, @mattermost_posts.size
      assert_includes @mattermost_posts[0][:message], ":white_check_mark:"
    end

    test "poll_sessions posts stalled alert after threshold" do
      @tmux_store.save(build_info(name: "stuck"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Waiting for something...\nStill waiting...\n"

      5.times { call_poll_sessions }

      stall_posts = @mattermost_posts.select { |post| post[:message].include?(":hourglass:") }
      assert stall_posts.size >= 1, "Expected at least one stall alert"
    end

    # -- forward_question tests --------------------------------------------------

    test "forward_question posts question with emoji reactions" do
      @tmux_store.save(build_info(name: "q-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Which file do you want to edit?\n1. foo.rb\n2. bar.rb\n"

      call_poll_sessions

      assert_equal 1, @mattermost_posts.size
      assert_includes @mattermost_posts[0][:message], ":question:"
      assert_includes @mattermost_posts[0][:message], "foo.rb"
      assert_includes @mattermost_posts[0][:message], "bar.rb"

      # Should add emoji reactions (one, two)
      assert_equal 2, @mattermost_reactions.size
      assert_equal "one", @mattermost_reactions[0][:emoji_name]
      assert_equal "two", @mattermost_reactions[1][:emoji_name]
    end

    # -- forward_permission tests ------------------------------------------------

    test "forward_question continues adding reactions when one fails" do
      @tmux_store.save(build_info(name: "q-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Which option?\n1. foo\n2. bar\n3. baz\n"

      # Make the second reaction fail
      call_count = 0
      @mattermost.define_singleton_method(:add_reaction) do |post_id:, emoji_name:|
        call_count += 1
        raise "network error" if call_count == 2

        @mattermost_reactions_for_partial ||= []
        @mattermost_reactions_for_partial << { post_id: post_id, emoji_name: emoji_name }
      end

      # Should not raise
      assert_nothing_raised { call_poll_sessions }
    end

    # -- forward_permission tests ------------------------------------------------

    test "forward_permission posts permission prompt with reactions" do
      @tmux_store.save(build_info(name: "perm-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Tool: Bash\nCommand: rm -rf /tmp/foo\nDo you want to allow this action?\n"

      call_poll_sessions

      assert_equal 1, @mattermost_posts.size
      assert_includes @mattermost_posts[0][:message], ":lock:"
      assert_includes @mattermost_posts[0][:message], "perm-session"

      # Should add approve/deny reactions
      assert_equal 2, @mattermost_reactions.size
      assert_equal "white_check_mark", @mattermost_reactions[0][:emoji_name]
      assert_equal "x", @mattermost_reactions[1][:emoji_name]
    end

    # -- start/stop tests --------------------------------------------------------

    test "start creates a background thread" do
      @monitor.start
      sleep 0.05
      thread_ctl = @monitor.instance_variable_get(:@thread_ctl)
      assert thread_ctl.alive?
    ensure
      @monitor.stop
    end

    test "stop kills the background thread" do
      @monitor.start
      sleep 0.05
      @monitor.stop
      thread_ctl = @monitor.instance_variable_get(:@thread_ctl)
      assert_not thread_ctl.alive?
    end

    test "stop handles nil thread gracefully" do
      # Should not raise when called without start
      assert_nothing_raised { @monitor.stop }
    end

    test "start is idempotent when thread is already running" do
      @monitor.start
      sleep 0.05

      # Capture internal thread reference for comparison
      thread1 = @monitor.instance_variable_get(:@thread_ctl).instance_variable_get(:@thread)
      @monitor.start
      thread2 = @monitor.instance_variable_get(:@thread_ctl).instance_variable_get(:@thread)

      assert_same thread1, thread2
    ensure
      @monitor.stop
    end

    # -- post_alert error handling -----------------------------------------------

    test "post_alert rescues errors gracefully" do
      info = build_info(name: "test")
      @tmux_store.save(info)
      stored = @tmux_store.get("test")

      # Make create_post raise
      @mattermost.define_singleton_method(:create_post) { |**_| raise "network error" }

      # Should not raise
      assert_nothing_raised do
        @monitor.send(:post_alert, stored, "test message")
      end
    end

    # -- question_forwarder edge cases ------------------------------------------

    test "forward_question skips when question is not parseable" do
      @tmux_store.save(build_info(name: "no-q-session"))
      @tmux_adapter.session_exists_result = true
      # Output has question pattern but no numbered options to parse
      @tmux_adapter.capture_pane_result = "Some output without parseable question mark but no numbers\n"

      call_poll_sessions

      # No question posts, only state-based alerts
      question_posts = @mattermost_posts.select { |p| p[:message].include?(":question:") }
      assert_empty question_posts
    end

    test "forward_question handles post failure gracefully" do
      @tmux_store.save(build_info(name: "q-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Which file?\n1. foo.rb\n2. bar.rb\n"

      # Make create_post raise
      @mattermost.define_singleton_method(:create_post) { |**_| raise "network error" }

      assert_nothing_raised { call_poll_sessions }
      # No pending interactions should be registered
      assert_empty poll_state.pending_interactions
    end

    test "forward_question handles nil post_id in response" do
      @tmux_store.save(build_info(name: "q-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Which file?\n1. foo.rb\n2. bar.rb\n"

      # Return a post without "id" key
      @mattermost.define_singleton_method(:create_post) { |**_| {} }

      assert_nothing_raised { call_poll_sessions }
      assert_empty poll_state.pending_interactions
    end

    # -- permission_forwarder edge cases ----------------------------------------

    test "forward_permission handles post failure gracefully" do
      @tmux_store.save(build_info(name: "perm-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Do you want to allow this action?\n"

      @mattermost.define_singleton_method(:create_post) { |**_| raise "network error" }

      assert_nothing_raised { call_poll_sessions }
      assert_empty poll_state.pending_interactions
    end

    test "forward_permission handles nil post_id in response" do
      @tmux_store.save(build_info(name: "perm-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Do you want to allow this action?\n"

      @mattermost.define_singleton_method(:create_post) { |**_| {} }

      assert_nothing_raised { call_poll_sessions }
      assert_empty poll_state.pending_interactions
    end

    # -- dispatch_state_alert tests -----------------------------------------------

    test "dispatch_state_alert posts error message for errored state" do
      info = build_info(name: "err-session")
      @tmux_store.save(info)
      stored = @tmux_store.get("err-session")

      @monitor.send(:dispatch_state_alert, :errored,
                    name: "err-session", output: "Running task...\nError: something broke\n", info: stored)

      assert_equal 1, @mattermost_posts.size
      assert_includes @mattermost_posts[0][:message], ":x:"
      assert_includes @mattermost_posts[0][:message], "err-session"
    end

    test "dispatch_state_alert posts completed message" do
      info = build_info(name: "done-session")
      @tmux_store.save(info)
      stored = @tmux_store.get("done-session")

      @monitor.send(:dispatch_state_alert, :completed,
                    name: "done-session", output: "done\nuser@host:~$ ", info: stored)

      assert_equal 1, @mattermost_posts.size
      assert_includes @mattermost_posts[0][:message], ":white_check_mark:"
    end

    test "dispatch_state_alert posts stalled message" do
      info = build_info(name: "stuck")
      @tmux_store.save(info)
      stored = @tmux_store.get("stuck")

      @monitor.send(:dispatch_state_alert, :stalled,
                    name: "stuck", output: "Waiting...\n", info: stored)

      assert_equal 1, @mattermost_posts.size
      assert_includes @mattermost_posts[0][:message], ":hourglass:"
    end

    test "dispatch_state_alert does nothing for running state" do
      info = build_info(name: "active")
      @tmux_store.save(info)
      stored = @tmux_store.get("active")

      @monitor.send(:dispatch_state_alert, :running,
                    name: "active", output: "working...\n", info: stored)

      assert_empty @mattermost_posts
    end

    # -- ThreadControl tests --------------------------------------------------

    test "ThreadControl stop kills alive thread after join timeout" do
      ctl = Earl::TmuxMonitor::ThreadControl.new
      ctl.start { sleep 0.01 until ctl.shutdown? }
      sleep 0.05

      assert ctl.alive?
      ctl.stop
      assert_not ctl.alive?
    end

    test "ThreadControl shutdown? returns false initially" do
      ctl = Earl::TmuxMonitor::ThreadControl.new
      assert_not ctl.shutdown?
    end

    test "ThreadControl shutdown? returns true after stop" do
      ctl = Earl::TmuxMonitor::ThreadControl.new
      ctl.stop
      assert ctl.shutdown?
    end

    # -- PollState edge case tests --------------------------------------------------

    test "PollState cleanup_session removes tracking and pending interactions" do
      ps = poll_state
      ps.transition("session-a", :running)
      ps.pending_interactions["post-1"] = { session_name: "session-a", type: :question }
      ps.pending_interactions["post-2"] = { session_name: "session-b", type: :permission }

      ps.cleanup_session("session-a")

      assert_nil ps.pending_interactions["post-1"]
      assert_not_nil ps.pending_interactions["post-2"]
    end

    test "handle_reaction returns nil for unknown interaction type" do
      # Seed a pending interaction with an unknown type
      poll_state.pending_interactions["post-unknown"] = {
        session_name: "test-session", type: :unknown_type
      }

      result = @monitor.handle_reaction(post_id: "post-unknown", emoji_name: "one")
      assert_nil result
    end

    test "detect_state handles nil-safe branches for empty line arrays" do
      # Output with no lines at all — covers &. nil safety
      assert_equal :running, call_detect_state("")
    end

    test "forward_question skips when output has question mark but more than 4 options only takes 4" do
      @tmux_store.save(build_info(name: "big-q"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "Pick one?\n1. A\n2. B\n3. C\n4. D\n5. E\n"

      call_poll_sessions

      # Question should be posted with only first 4 options
      question_posts = @mattermost_posts.select { |p| p[:message].include?(":question:") }
      assert_equal 1, question_posts.size
      assert_includes question_posts[0][:message], "A"
      assert_includes question_posts[0][:message], "D"
      assert_not_includes question_posts[0][:message], "E"

      # Should have exactly 4 emoji reactions
      assert_equal 4, @mattermost_reactions.size
    end

    test "poll_loop rescues errors and continues" do
      @tmux_store.save(build_info(name: "err-session"))
      @tmux_adapter.session_exists_result = true
      @tmux_adapter.capture_pane_result = "normal output\n"

      # Make poll_sessions raise to trigger the rescue in poll_loop
      poll_count = 0
      @monitor.define_singleton_method(:poll_sessions) do
        poll_count += 1
        raise "poll explosion" if poll_count == 1
      end

      thread_ctl = @monitor.instance_variable_get(:@thread_ctl)
      thread_ctl.start do
        sleep 0.01
        begin
          @monitor.send(:poll_sessions)
        rescue StandardError
          nil
        end
        thread_ctl.instance_variable_set(:@shutdown, true)
      end
      thread_ctl.instance_variable_get(:@thread)&.join(1)

      assert poll_count >= 1
    end

    test "permission_forwarder builds context from last 15 lines" do
      @tmux_store.save(build_info(name: "perm-ctx"))
      @tmux_adapter.session_exists_result = true
      # Build output with many lines so last(15) is exercised
      lines = (1..20).map { |i| "Line #{i}\n" }.join
      @tmux_adapter.capture_pane_result = "#{lines}Do you want to allow this action?\n"

      call_poll_sessions

      # Should post a permission prompt containing some of the last lines
      perm_posts = @mattermost_posts.select { |p| p[:message].include?(":lock:") }
      assert_equal 1, perm_posts.size
    end

    test "OutputAnalyzer.completed? returns false for single non-prompt line" do
      assert_not Earl::TmuxMonitor::OutputAnalyzer.completed?(["still running\n"])
    end

    test "OutputAnalyzer.completed? returns false for empty array" do
      assert_not Earl::TmuxMonitor::OutputAnalyzer.completed?([])
    end

    test "OutputAnalyzer.state_from_patterns returns nil for empty lines" do
      assert_nil Earl::TmuxMonitor::OutputAnalyzer.state_from_patterns([])
    end

    test "OutputAnalyzer.state_from_patterns returns nil for short non-matching output" do
      assert_nil Earl::TmuxMonitor::OutputAnalyzer.state_from_patterns(["normal line\n"])
    end

    test "ThreadControl stop with no thread does not raise" do
      ctl = Earl::TmuxMonitor::ThreadControl.new
      assert_nothing_raised { ctl.stop }
      assert_not ctl.alive?
    end

    test "error_message includes last 10 lines of output" do
      output = (1..15).map { |i| "line #{i}\n" }.join
      info = build_info(name: "err-test")
      @tmux_store.save(info)
      @tmux_store.get("err-test")

      msg = @monitor.send(:error_message, "err-test", output)
      assert_includes msg, ":x:"
      assert_includes msg, "err-test"
      assert_includes msg, "line 15"
      assert_not_includes msg, "line 4"
    end

    test "error_message handles empty output" do
      msg = @monitor.send(:error_message, "empty-sess", "")
      assert_includes msg, ":x:"
      assert_includes msg, "empty-sess"
    end

    private

    # -- Helpers: access internal state ------------------------------------------

    def poll_state
      @monitor.instance_variable_get(:@poll_state)
    end

    # -- Helpers: call private methods via send ----------------------------------

    def call_detect_state(output, name = "test-session")
      Earl::TmuxMonitor::OutputAnalyzer.detect(output, name, poll_state)
    end

    def call_state_changed?(name, state)
      poll_state.transition(name, state)
    end

    def set_last_state(name, state)
      ps = poll_state
      ps.send(:ensure_tracking, name)
      ps.instance_variable_get(:@tracking)[name][:last_state] = state
    end

    def call_parse_question(output)
      @monitor.parse_question(output)
    end

    def call_poll_sessions
      @monitor.send(:poll_sessions)
    end

    # -- Helpers: pending interaction seeding ------------------------------------

    def seed_pending_interaction(post_id, type:, options: nil)
      interaction = { session_name: "test-session", type: type }
      interaction[:options] = options if options
      poll_state.pending_interactions[post_id] = interaction
    end

    def add_pending_interaction(post_id, session_name:, type:, options: nil)
      interaction = { session_name: session_name, type: type }
      interaction[:options] = options if options
      poll_state.pending_interactions[post_id] = interaction
    end

    # -- Helpers: Configure send_keys to raise -----------------------------------

    def configure_send_keys_error
      @tmux_adapter.send_keys_error = Earl::Tmux::Error.new("session not found")
    end

    # -- Helpers: Mock tmux adapter (process-local, no global state) -------------

    def build_mock_tmux_adapter
      @tmux_send_keys_calls = []
      MockTmuxAdapter.new(@tmux_send_keys_calls)
    end

    # Lightweight test double for Earl::Tmux that avoids global singleton mutation.
    # Each test gets its own instance, so parallel tests never interfere.
    class MockTmuxAdapter
      attr_accessor :session_exists_result, :capture_pane_result,
                    :capture_pane_error, :send_keys_error

      def initialize(send_keys_calls)
        @send_keys_calls = send_keys_calls
        @session_exists_result = true
        @capture_pane_result = ""
        @capture_pane_error = nil
        @send_keys_error = nil
      end

      def session_exists?(_name)
        @session_exists_result
      end

      def capture_pane(_name, **_opts)
        raise @capture_pane_error if @capture_pane_error

        @capture_pane_result
      end

      def send_keys(target, text)
        raise @send_keys_error if @send_keys_error

        @send_keys_calls << { target: target, text: text }
      end
    end

    # -- Helpers: Mock mattermost ------------------------------------------------

    def build_mock_mattermost
      @mattermost_posts = []
      @mattermost_reactions = []
      posts = @mattermost_posts
      reactions = @mattermost_reactions

      mattermost = Object.new

      mattermost.define_singleton_method(:create_post) do |channel_id:, message:, root_id: nil|
        post_id = "post-#{posts.size + 1}"
        posts << { channel_id: channel_id, message: message, root_id: root_id, id: post_id }
        { "id" => post_id }
      end

      mattermost.define_singleton_method(:add_reaction) do |post_id:, emoji_name:|
        reactions << { post_id: post_id, emoji_name: emoji_name }
      end

      mattermost
    end

    # -- Helpers: Session info ---------------------------------------------------

    def build_info(name: "test-session")
      Earl::TmuxSessionStore::TmuxSessionInfo.new(
        name: name,
        channel_id: "channel-1",
        thread_id: "thread-1",
        working_dir: "/tmp/project",
        prompt: "hello world",
        created_at: Time.now.iso8601
      )
    end

    # Adapter that raises on one session but returns error output for others.
    def build_selective_error_adapter(error_session, default_output)
      adapter = Object.new
      err_name = error_session
      output = default_output

      adapter.define_singleton_method(:session_exists?) { |_name| true }
      adapter.define_singleton_method(:capture_pane) do |name, **_opts|
        raise StandardError, "unexpected error" if name == err_name

        output
      end
      adapter.define_singleton_method(:send_keys) { |_target, _text| nil }
      adapter
    end
  end
end
