# frozen_string_literal: true

module Earl
  module Mcp
    class ConversationHandler
      # Builds analysis-type-specific system prompts for conversation analysis.
      module AnalysisPrompt
        ANALYSIS_TYPES = %w[general troubleshooting sentiment action_items code_review].freeze

        PROMPTS = {
          "general" => "Analyze this Mattermost conversation thread. Provide a clear summary of " \
                       "the discussion, key points raised, decisions made, and any unresolved questions.",
          "troubleshooting" => "Analyze this Mattermost conversation thread as a troubleshooting session. " \
                               "Identify the problem reported, steps taken to diagnose, solutions attempted, " \
                               "what worked or didn't, and any remaining issues to resolve.",
          "sentiment" => "Analyze the sentiment and tone of this Mattermost conversation thread. " \
                         "Identify the overall mood, any frustration or satisfaction expressed, " \
                         "communication dynamics between participants, and areas of agreement or tension.",
          "action_items" => "Extract all action items from this Mattermost conversation thread. " \
                            "For each item, identify who is responsible, what needs to be done, " \
                            "any deadlines mentioned, and the current status (completed, pending, blocked).",
          "code_review" => "Analyze this Mattermost conversation thread as a code review discussion. " \
                           "Identify code changes discussed, feedback given, issues raised, " \
                           "approved or rejected changes, and any follow-up work needed."
        }.freeze

        private

        def build_analysis_prompt(analysis_type, focus)
          base = PROMPTS.fetch(analysis_type)
          focus ? "#{base}\n\nFocus specifically on: #{focus}" : base
        end
      end
    end
  end
end
