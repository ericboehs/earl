# frozen_string_literal: true

require "open3"

module Earl
  # Shell wrapper module for interacting with tmux. Provides methods for
  # listing sessions/panes, capturing output, sending keys, and managing
  # sessions. All commands use Open3.capture2e for safe shell execution.
  module Tmux
    # Raised when a tmux command fails with a non-zero exit status.
    class Error < StandardError; end

    # Raised when a tmux session or pane cannot be found.
    class NotFound < Error; end

    # Delay between sending literal text and pressing Enter in send_keys.
    SEND_KEYS_DELAY = 0.1

    module_function

    def available?
      _, status = Open3.capture2e("which", "tmux")
      status.success?
    end

    # :reek:DuplicateMethodCall
    def list_sessions
      output = execute("tmux", "list-sessions", "-F",
                        '#{session_name}\t#{session_attached}\t#{session_created_string}')
      output.each_line.map do |line|
        parts = line.strip.split("\t", 3)
        next if parts.size < 3

        {
          name: parts[0],
          attached: parts[1] == "1",
          created_at: parts[2]
        }
      end.compact
    rescue Error => error
      return [] if error.message.include?("no server running") || error.message.include?("no sessions")

      raise
    end

    def list_panes(session)
      output = execute("tmux", "list-panes", "-t", session, "-F",
                        '#{pane_index}\t#{pane_current_command}\t#{pane_current_path}\t#{pane_pid}')
      output.each_line.map do |line|
        parts = line.strip.split("\t", 4)
        next if parts.size < 4

        {
          index: parts[0].to_i,
          command: parts[1],
          path: parts[2],
          pid: parts[3].to_i
        }
      end.compact
    rescue Error => error
      raise NotFound, "Session '#{session}' not found" if error.message.include?("can't find")

      raise
    end

    def capture_pane(target, lines: 100)
      execute("tmux", "capture-pane", "-t", target, "-p", "-J", "-S", "-#{lines}")
    rescue Error => error
      raise NotFound, "Target '#{target}' not found" if error.message.include?("can't find")

      raise
    end

    # Sends text to a tmux pane using the two-step pattern required by
    # Claude Code TUI apps: send text with -l (literal), sleep briefly, then
    # send Enter separately. This prevents Claude from treating it as paste.
    #
    # NOTE: There is an inherent race window between the two tmux commands.
    # Another process could interleave keystrokes between the literal text
    # and the Enter press. The SEND_KEYS_DELAY mitigates but cannot eliminate
    # this; tmux has no atomic "send text + enter" primitive.
    def send_keys(target, text)
      execute("tmux", "send-keys", "-t", target, "-l", "--", text)
      sleep SEND_KEYS_DELAY
      execute("tmux", "send-keys", "-t", target, "Enter")
    end

    # Sends raw key sequences (e.g. "C-c") without -l flag.
    def send_keys_raw(target, key)
      execute("tmux", "send-keys", "-t", target, key)
    end

    def create_session(name:, command: nil, working_dir: nil)
      args = [ "tmux", "new-session", "-d", "-s", name ]
      args.push("-c", working_dir) if working_dir
      args.push(command) if command
      execute(*args)
    end

    def kill_session(name)
      execute("tmux", "kill-session", "-t", name)
    rescue Error => error
      raise NotFound, "Session '#{name}' not found" if error.message.include?("can't find")

      raise
    end

    def session_exists?(name)
      execute("tmux", "has-session", "-t", name)
      true
    rescue Error
      false
    end

    # Polls capture_pane output until pattern matches or timeout. Inspired by
    # OpenClaw's wait-for-text.sh pattern. Returns matched output or nil on timeout.
    # :reek:LongParameterList :reek:DuplicateMethodCall
    def wait_for_text(target, pattern, timeout: 15, interval: 0.5, lines: 200)
      regex = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
      deadline = Time.now + timeout

      while Time.now < deadline
        output = capture_pane(target, lines: lines)
        return output if output.match?(regex)

        sleep interval
      end

      nil
    end

    class << self
      private

      def execute(*cmd)
        output, status = Open3.capture2e(*cmd)
        raise Error, "tmux command failed: #{cmd.join(' ')}: #{output.strip}" unless status.success?

        output
      end
    end
  end
end
