# frozen_string_literal: true

require_relative "conversation_diagnoser/transcript_formatter"
require_relative "conversation_diagnoser/analysis_prompt"
require_relative "conversation_diagnoser/subprocess"
require_relative "conversation_diagnoser/issue_approval"
require_relative "conversation_diagnoser/github_issue"

module Earl
  module Mcp
    # MCP handler exposing an analyze_conversation tool that fetches a
    # Mattermost thread, runs an EARL-focused diagnostic via `claude --print`,
    # posts the analysis for user review, and optionally creates a GitHub issue
    # on approval. Conforms to the Server handler interface: tool_definitions,
    # handles?, call.
    class ConversationDiagnoser
      include Logging
      include HandlerBase

      TOOL_NAMES = %w[analyze_conversation].freeze

      def initialize(config:, api_client:)
        @config = config
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
        text_content("Error: thread_id is required") unless thread_id && !thread_id.empty?
      end

      def handle_analyze(arguments)
        thread_id = arguments["thread_id"]
        focus = arguments["focus"]

        analysis = run_diagnostic(thread_id, focus)
        return text_content(analysis) if analysis.start_with?("Error:")

        user_analysis, sanitized_issue = split_analysis(analysis)
        result = approve_and_create_issue(user_analysis, sanitized_issue, thread_id)
        text_content(result)
      end

      def run_diagnostic(thread_id, focus)
        transcript = fetch_and_format_transcript(thread_id)
        prompt = build_analysis_prompt(focus)
        run_analysis(prompt, transcript)
      end

      def split_analysis(analysis)
        parts = analysis.split(/^---\s*$/, 2)
        user_analysis = parts[0].strip
        sanitized_issue = parts[1]&.strip || ""
        [user_analysis, sanitized_issue]
      end

      def approve_and_create_issue(user_analysis, sanitized_issue, thread_id)
        decision = request_issue_approval(user_analysis, thread_id)
        return format_error_result(user_analysis) if decision == :error
        return format_denied_result(user_analysis) unless decision == :approved

        issue_url = create_issue_from_analysis(sanitized_issue, thread_id)
        format_approved_result(user_analysis, issue_url)
      end

      def create_issue_from_analysis(sanitized_issue, thread_id)
        thread_url = build_thread_url(thread_id)
        create_github_issue(sanitized_issue, thread_url)
      end

      def format_approved_result(analysis, issue_url)
        "#{analysis}\n\n---\n:white_check_mark: GitHub issue created: #{issue_url}"
      end

      def format_denied_result(analysis)
        "#{analysis}\n\n---\n:no_entry_sign: Issue creation skipped."
      end

      def format_error_result(analysis)
        "#{analysis}\n\n---\n:warning: Could not request approval (posting or WebSocket error)."
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
          "Analyze a Mattermost conversation thread for EARL behavior issues. " \
            "Fetches the thread, runs AI diagnostic, posts analysis for review, " \
            "and optionally creates a GitHub issue on approval."
        end

        def analyze_input_schema
          { type: "object", properties: analyze_properties, required: %w[thread_id] }
        end

        def analyze_properties
          {
            thread_id: thread_id_property,
            focus: focus_property
          }
        end

        def thread_id_property
          { type: "string", description: "The Mattermost post ID of the thread root to analyze" }
        end

        def focus_property
          {
            type: "string",
            description: "Optional focus area to narrow the analysis " \
                         "(e.g., 'error handling', 'tool usage', 'hallucinations')"
          }
        end
      end

      include TranscriptFormatter
      include AnalysisPrompt
      include Subprocess
      include IssueApproval
      include ApprovalPolling
      include ApprovalClassification
      include GithubIssue
      include ToolDefinitionBuilder
    end
  end
end
