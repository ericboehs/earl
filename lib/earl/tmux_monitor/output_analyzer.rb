# frozen_string_literal: true

module Earl
  class TmuxMonitor
    # Stateless output analysis that detects tmux session state from captured text.
    module OutputAnalyzer
      SHELL_PROMPT_PATTERN = /[❯#%]\s*\z|\$\s+\z/

      module_function

      def detect(output, name, poll_state)
        all_lines = output.lines
        return :completed if completed?(all_lines)

        state_from_patterns(all_lines) || stall_or_running(name, output, poll_state)
      end

      def completed?(all_lines)
        (all_lines.last(3)&.join || "").match?(SHELL_PROMPT_PATTERN)
      end

      def state_from_patterns(all_lines)
        recent = all_lines.last(15)&.join || ""
        STATE_PATTERNS.each do |state, pattern|
          return state if recent.match?(pattern)
        end
        nil
      end

      def stall_or_running(name, output, poll_state)
        poll_state.stalled?(name, output) ? :stalled : :running
      end
    end
  end
end
