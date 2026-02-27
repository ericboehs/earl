# frozen_string_literal: true

module Earl
  module Mcp
    class ConversationDiagnoser
      # Single EARL-focused diagnostic prompt for conversation analysis.
      # Produces two-part output separated by "---": a detailed Mattermost
      # analysis (PART 1) and a sanitized GitHub issue body (PART 2).
      module AnalysisPrompt
        EARL_DIAGNOSTIC_PROMPT = <<~PROMPT
          You are analyzing a conversation between a user and EARL (an AI assistant bot
          running on Mattermost). Your goal is to identify what went wrong or could be
          improved in EARL's behavior.

          Analyze the conversation for:
          1. **Errors**: Wrong answers, hallucinations, failed tool calls, misunderstood requests
          2. **Missed opportunities**: Better tools/approaches EARL should have used
          3. **UX issues**: Confusing responses, unnecessary verbosity, poor formatting
          4. **System issues**: Timeouts, crashes, permission problems, session issues

          Produce TWO outputs separated by "---":

          PART 1 -- Full Analysis (shown to user in Mattermost):
          A detailed breakdown of what happened and recommendations.

          PART 2 -- GitHub Issue (sanitized, no PII or conversation content):
          Title: <concise bug/improvement title>
          Labels: bug OR enhancement
          Body: A generic description of the issue category and suggested fix.
          Do NOT include any conversation content, usernames, or personal information.
          Reference only the type of problem (e.g., "EARL fails to handle X pattern").
        PROMPT

        private

        def build_analysis_prompt(focus)
          focus ? "#{EARL_DIAGNOSTIC_PROMPT}\n\nFocus specifically on: #{focus}" : EARL_DIAGNOSTIC_PROMPT
        end
      end
    end
  end
end
