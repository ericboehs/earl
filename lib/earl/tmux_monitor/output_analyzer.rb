# frozen_string_literal: true

module Earl
  class TmuxMonitor
    # Stateless output analysis that detects tmux session state from captured text.
    module OutputAnalyzer
      SHELL_PROMPT_PATTERN = /[❯#%]\s*\z|\$\s+\z/
      # Claude Code shows ❯ alone on a line when idle, but decoration lines
      # (separators, status bar, blanks) appear below it in the pane.
      # Uses \p{Z} (Unicode whitespace) since tmux inserts non-breaking spaces.
      CLAUDE_IDLE_PATTERN = /\A[\s\p{Zs}]*❯[\s\p{Zs}]*\z/

      module_function

      def detect(output, name, poll_state)
        all_lines = output.lines
        return :completed if completed?(all_lines)

        state_from_patterns(all_lines) || stall_or_running(name, output, poll_state)
      end

      def completed?(all_lines)
        shell_prompt?(all_lines) || claude_idle?(all_lines)
      end

      def shell_prompt?(all_lines)
        (all_lines.last(3)&.join || "").match?(SHELL_PROMPT_PATTERN)
      end

      def claude_idle?(all_lines)
        (all_lines.last(15) || []).any? { |line| line.match?(CLAUDE_IDLE_PATTERN) }
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

      SEPARATOR_PATTERN = /\A\s*[─━═]+\s*\z/

      # Extracts Claude's last response from captured pane output by finding text
      # between the last user input (❯ + text) and the idle prompt (❯ alone).
      def extract_last_response(output)
        lines = output.lines.map(&:rstrip)
        idle_idx = lines.rindex { |line| line.match?(CLAUDE_IDLE_PATTERN) }
        return nil unless idle_idx

        input_idx = find_last_user_input(lines, idle_idx)
        return nil unless input_idx

        extract_response_lines(lines, input_idx, idle_idx)
      end

      def find_last_user_input(lines, before_idx)
        (before_idx - 1).downto(0).find { |idx| lines[idx].match?(/\A❯\s+\S/) }
      end

      def extract_response_lines(lines, input_idx, idle_idx)
        lines[(input_idx + 1)...idle_idx]
          .map { |line| line.sub(/\A⏺\s*/, "").strip }
          .reject { |line| line.empty? || line.match?(SEPARATOR_PATTERN) }
          .join(" ")
          .then { |text| text.empty? ? nil : text }
      end
    end
  end
end
