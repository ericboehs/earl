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

    # Delimiter for tmux -F format strings. Tmux 3.6+ treats \t as literal
    # backslash-t rather than a tab character, so we use a multi-char delimiter
    # that won't appear in session names, commands, or paths.
    FIELD_SEP = "|||"

    module_function

    def available?
      _, status = Open3.capture2e("which", "tmux")
      status.success?
    end

    def list_sessions
      fmt = %w[session_name session_attached session_created].map { |field| "\#{#{field}}" }.join(FIELD_SEP)
      output = execute("tmux", "list-sessions", "-F", fmt)
      output.each_line.map do |line|
        parts = line.strip.split(FIELD_SEP, 3)
        next if parts.size < 3

        {
          name: parts[0],
          attached: parts[1] != "0",
          created_at: Time.at(parts[2].to_i).strftime("%c")
        }
      end.compact
    rescue Error => error
      return [] if error.message.include?("no server running") || error.message.include?("no sessions")

      raise
    end

    def list_panes(session)
      fmt = %w[pane_index pane_current_command pane_current_path pane_pid].map { |field| "\#{#{field}}" }.join(FIELD_SEP)
      output = execute("tmux", "list-panes", "-t", session, "-F", fmt)
      output.each_line.map do |line|
        parts = line.strip.split(FIELD_SEP, 4)
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

    # Lists all panes across all sessions and windows with session/window context.
    # Returns an array of hashes with :target (e.g. "code:1.0"), :session, :window,
    # :pane_index, :command, :path, :pid, and :tty.
    def list_all_panes
      fields = %w[session_name window_index pane_index pane_current_command
                   pane_current_path pane_pid pane_tty]
      fmt = fields.map { |field| "\#{#{field}}" }.join(FIELD_SEP)
      output = execute("tmux", "list-panes", "-a", "-F", fmt)
      output.each_line.map do |line|
        parts = line.strip.split(FIELD_SEP, fields.size)
        next if parts.size < fields.size

        session, window, pane_idx = parts[0], parts[1], parts[2]
        {
          target: "#{session}:#{window}.#{pane_idx}",
          session: session,
          window: window.to_i,
          pane_index: pane_idx.to_i,
          command: parts[3],
          path: parts[4],
          pid: parts[5].to_i,
          tty: parts[6]
        }
      end.compact
    rescue Error => error
      return [] if error.message.include?("no server running") || error.message.include?("no sessions")

      raise
    end

    # Checks whether a Claude process is running on the given tty.
    # Uses `ps -t <tty>` which is more reliable than walking the process tree,
    # since Claude Code reports its version string as the process name.
    def claude_on_tty?(tty)
      tty_name = tty.sub(%r{\A/dev/}, "")
      output, _ = Open3.capture2e("ps", "-t", tty_name, "-o", "command=")
      output.each_line.any? { |line| line.match?(%r{/claude\b|^claude\b}i) }
    rescue StandardError => error
      Earl.logger.debug("Tmux.claude_on_tty? failed for #{tty}: #{error.message}")
      false
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

    # Returns an array of command basenames for child processes of the given PID.
    # Used to detect what's actually running inside a pane when pane_current_command
    # reports an unhelpful value (e.g. Claude reports its version string "2.1.42").
    def pane_child_commands(pid)
      pid_str = pid.to_s
      output, _status = Open3.capture2e("ps", "-o", "comm=", "-p", pid_str)
      children, _ = Open3.capture2e("ps", "-eo", "pid=,ppid=,comm=")
      child_comms = children.each_line.filter_map do |line|
        parts = line.strip.split(/\s+/, 3)
        parts[2] if parts[1] == pid_str
      end

      ([ output.strip ] + child_comms).reject(&:empty?)
    rescue StandardError => error
      Earl.logger.debug("Tmux.pane_child_commands failed for PID #{pid}: #{error.message}")
      []
    end

    # Polls capture_pane output until pattern matches or timeout. Inspired by
    # OpenClaw's wait-for-text.sh pattern. Returns matched output or nil on timeout.
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
