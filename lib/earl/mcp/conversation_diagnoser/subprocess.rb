# frozen_string_literal: true

require "timeout"

module Earl
  module Mcp
    class ConversationDiagnoser
      # Spawns a one-shot `claude --print` subprocess for conversation analysis.
      module Subprocess
        TIMEOUT_SECONDS = 120

        private

        def run_analysis(prompt, transcript)
          full_prompt = "#{prompt}\n\n---\n\nThread transcript:\n\n#{transcript}"
          output, status = execute_claude(full_prompt)
          interpret_result(output, status)
        rescue Timeout::Error
          "Error: analysis timed out after #{TIMEOUT_SECONDS} seconds"
        end

        def execute_claude(full_prompt)
          Timeout.timeout(TIMEOUT_SECONDS) do
            Open3.capture2("claude", "--print", "-p", full_prompt, err: File::NULL)
          end
        end

        def interpret_result(output, status)
          return "Error: claude exited with status #{status.exitstatus}" unless status.success?

          trimmed = output.strip
          trimmed.empty? ? "Error: claude returned empty output" : trimmed
        end
      end
    end
  end
end
