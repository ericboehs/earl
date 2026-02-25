# frozen_string_literal: true

module Earl
  module Tmux
    # Process inspection: check for Claude on TTY, list child processes.
    module Processes
      def claude_on_tty?(tty)
        check_tty_for_claude(tty)
      end

      def pane_child_commands(pid)
        pid_str = pid.to_s
        parent_comm = fetch_parent_command(pid_str)
        all_entries = fetch_child_commands
        child_comms = all_entries.filter_map { |entry| entry[:comm] if entry[:ppid] == pid_str }
        ([parent_comm] + child_comms).reject(&:empty?)
      rescue StandardError => error
        Earl.logger.debug("Tmux.pane_child_commands failed for PID #{pid}: #{error.message}")
        []
      end

      private

      def check_tty_for_claude(tty)
        tty_name = tty.sub(%r{\A/dev/}, "")
        output, = Open3.capture2e("ps", "-t", tty_name, "-o", "command=") # nosemgrep
        output.each_line.any? { |line| line.match?(%r{/claude\b|^claude\b}i) }
      rescue StandardError => error
        Earl.logger.debug("Tmux.claude_on_tty? failed for #{tty}: #{error.message}")
        false
      end
    end
  end
end
