# frozen_string_literal: true

require "open3"
require_relative "tmux/parsing"
require_relative "tmux/sessions"
require_relative "tmux/processes"

module Earl
  # Shell wrapper module for interacting with tmux. Provides methods for
  # listing sessions/panes, capturing output, sending keys, and managing
  # sessions. All commands use Open3.capture2e for safe shell execution.
  module Tmux
    # Raised when a tmux command fails with a non-zero exit status.
    class Error < StandardError; end

    # Raised when a tmux session or pane cannot be found.
    class NotFound < Error; end

    SEND_KEYS_DELAY = 0.1
    FIELD_SEP = "|||"
    # Configuration for wait_for_text polling behavior.
    WaitConfig = Data.define(:timeout, :interval, :lines)
    WAIT_DEFAULTS = { timeout: 15, interval: 0.5, lines: 200 }.freeze
    # Specification for creating a new tmux window.
    WindowSpec = Data.define(:session, :name, :command, :working_dir)

    PANE_FIELDS = %w[pane_index pane_current_command pane_current_path pane_pid].freeze
    ALL_PANE_FIELDS = %w[session_name window_index pane_index pane_current_command
                         pane_current_path pane_pid pane_tty].freeze

    module_function

    def available?
      _, status = Open3.capture2e("which", "tmux")
      status.success?
    end

    def list_sessions
      fmt = build_format(%w[session_name session_attached session_created])
      output = execute("tmux", "list-sessions", "-F", fmt)
      output.each_line.filter_map { |line| parse_session_line(line) }
    rescue Error => error
      return [] if no_server_or_sessions?(error)

      raise
    end

    def list_panes(session)
      fmt = build_format(PANE_FIELDS)
      output = execute("tmux", "list-panes", "-t", session, "-F", fmt)
      parse_pane_lines(output, PANE_FIELDS.size)
    rescue Error => error
      raise NotFound, "Session '#{session}' not found" if error.message.include?("can't find")

      raise
    end

    def list_all_panes
      field_count = ALL_PANE_FIELDS.size
      fmt = build_format(ALL_PANE_FIELDS)
      output = execute("tmux", "list-panes", "-a", "-F", fmt)
      output.each_line.filter_map { |line| parse_all_pane_line(line, field_count) }
    rescue Error => error
      return [] if no_server_or_sessions?(error)

      raise
    end

    def capture_pane(target, lines: 100)
      execute("tmux", "capture-pane", "-t", target, "-p", "-J", "-S", "-#{lines}")
    rescue Error => error
      raise NotFound, "Target '#{target}' not found" if error.message.include?("can't find")

      raise
    end

    def send_keys(target, text)
      execute("tmux", "send-keys", "-t", target, "-l", "--", text)
      sleep SEND_KEYS_DELAY
      execute("tmux", "send-keys", "-t", target, "Enter")
    end

    def send_keys_raw(target, key)
      execute("tmux", "send-keys", "-t", target, key)
    end

    def wait_for_text(target, pattern, **)
      config = WaitConfig.new(**WAIT_DEFAULTS, **)
      regex = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
      poll_until_match(target, regex, config)
    end

    class << self
      include Parsing
      include Sessions
      include Processes

      private

      def execute(*cmd)
        output, status = Open3.capture2e(*cmd)
        raise Error, "tmux command failed: #{cmd.join(" ")}: #{output.strip}" unless status.success?

        output
      end

      def poll_until_match(target, regex, config)
        remaining = config.timeout
        poll_interval = config.interval

        loop do
          output = capture_pane(target, lines: config.lines)
          return output if output.match?(regex)
          return nil if remaining <= 0

          sleep poll_interval
          remaining -= poll_interval
        end
      end
    end
  end
end
