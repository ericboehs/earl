# frozen_string_literal: true

require_relative "conversation_handler/transcript_formatter"
require_relative "conversation_handler/analysis_prompt"
require_relative "conversation_handler/subprocess"

module Earl
  module Mcp
    # MCP handler exposing an analyze_conversation tool that fetches a
    # Mattermost thread, builds a type-specific prompt, and spawns a
    # one-shot `claude --print` subprocess to return structured analysis.
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class ConversationHandler
      include HandlerBase

      TOOL_NAMES = %w[analyze_conversation].freeze

      def initialize(api_client:)
        @api = api_client
      end

      def tool_definitions
        [analyze_conversation_definition]
      end

      def call(name, arguments)
        return unless handles?(name)

        error = validate_arguments(arguments)
        return error if error

        handle_analyze(arguments)
      end

      private

      def validate_arguments(arguments)
        thread_id = arguments["thread_id"]
        return text_content("Error: thread_id is required") unless thread_id && !thread_id.empty?

        analysis_type = arguments.fetch("analysis_type", "general")
        return if AnalysisPrompt::ANALYSIS_TYPES.include?(analysis_type)

        valid = AnalysisPrompt::ANALYSIS_TYPES.join(", ")
        text_content("Error: unknown analysis_type '#{analysis_type}'. Valid: #{valid}")
      end

      def handle_analyze(arguments)
        thread_id = arguments["thread_id"]
        analysis_type = arguments.fetch("analysis_type", "general")
        focus = arguments["focus"]

        transcript = fetch_and_format_transcript(thread_id)
        prompt = build_analysis_prompt(analysis_type, focus)
        analysis = run_analysis(prompt, transcript)
        text_content(analysis)
      end

      def text_content(text)
        { content: [{ type: "text", text: text }] }
      end

      # Tool definition schema.
      module ToolDefinitionBuilder
        private

        def analyze_conversation_definition
          {
            name: "analyze_conversation",
            description: analyze_tool_description,
            inputSchema: analyze_input_schema
          }
        end

        def analyze_tool_description
          "Analyze a Mattermost conversation thread. Fetches the thread transcript " \
            "and runs AI-powered analysis (summary, troubleshooting, sentiment, " \
            "action items, or code review)."
        end

        def analyze_input_schema
          { type: "object", properties: analyze_properties, required: %w[thread_id] }
        end

        def analyze_properties
          {
            thread_id: thread_id_property,
            analysis_type: analysis_type_property,
            focus: focus_property
          }
        end

        def thread_id_property
          { type: "string", description: "The Mattermost post ID of the thread root to analyze" }
        end

        def analysis_type_property
          {
            type: "string",
            enum: AnalysisPrompt::ANALYSIS_TYPES,
            description: "Type of analysis to perform (default: general)"
          }
        end

        def focus_property
          {
            type: "string",
            description: "Optional focus area to narrow the analysis (e.g., 'error handling', 'deployment steps')"
          }
        end
      end

      include TranscriptFormatter
      include AnalysisPrompt
      include Subprocess
      include ToolDefinitionBuilder
    end
  end
end
