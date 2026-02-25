# frozen_string_literal: true

require_relative "question_handler/question_posting"

module Earl
  # Handles AskUserQuestion tool_use events from Claude by posting numbered
  # options to Mattermost and collecting answers via emoji reactions.
  class QuestionHandler
    include Logging
    include QuestionPosting

    EMOJI_NUMBERS = %w[one two three four].freeze
    EMOJI_MAP = { "one" => 0, "two" => 1, "three" => 2, "four" => 3 }.freeze

    # Tracks in-progress question flow: which tool_use triggered it, the list of
    # questions, collected answers, and the Mattermost post/thread IDs.
    QuestionState = Struct.new(:tool_use_id, :questions, :answers, :current_index,
                               :current_post_id, :thread_id, :channel_id, keyword_init: true) do
      def current_question
        questions[current_index]
      end

      def all_questions_answered?
        current_index >= questions.size
      end
    end

    def initialize(mattermost:)
      @mattermost = mattermost
      @pending_questions = {} # post_id -> QuestionState
      @mutex = Mutex.new
    end

    def handle_tool_use(thread_id:, tool_use:, channel_id: nil)
      name, input, tool_use_id = tool_use.values_at(:name, :input, :id)
      return nil unless name == "AskUserQuestion"

      questions = input["questions"] || []
      return nil if questions.empty?

      state = QuestionState.new(
        tool_use_id: tool_use_id, questions: questions, answers: {},
        current_index: 0, thread_id: thread_id, channel_id: channel_id
      )
      start_question_flow(state, tool_use_id)
    end

    def handle_reaction(post_id:, emoji_name:)
      state = fetch_pending(post_id)
      return nil unless state

      selected = resolve_selected_option(state, emoji_name)
      return nil unless selected

      accept_answer(state, post_id, selected)
    end

    private

    def start_question_flow(state, tool_use_id)
      unless post_current_question(state)
        log(:error, "Failed to post question for tool_use #{tool_use_id}, returning error answer")
        return { tool_use_id: tool_use_id, answer_text: "Failed to post question to chat" }
      end

      { tool_use_id: tool_use_id }
    end

    def fetch_pending(post_id)
      @mutex.synchronize { @pending_questions[post_id] }
    end

    def release_pending(post_id)
      @mutex.synchronize { @pending_questions.delete(post_id) }
      delete_question_post(post_id)
    end

    def accept_answer(state, post_id, selected)
      index = state.current_index
      record_answer(state, state.questions[index], selected)
      release_pending(post_id)
      advance_question(state, index)
    end

    def advance_question(state, index)
      next_index = index + 1
      state.current_index = next_index
      return build_answer_json(state) unless next_index < state.questions.size

      post_current_question(state)
      nil
    end

    def resolve_selected_option(state, emoji_name)
      answer_index = EMOJI_MAP[emoji_name]
      return nil unless answer_index

      options = state.questions[state.current_index]["options"] || []
      answer_index < options.size ? options[answer_index] : nil
    end

    def record_answer(state, question, selected_option)
      state.answers[question["question"]] = selected_option["label"] || selected_option.to_s
    end

    def build_answer_json(state)
      answers = state.questions.map.with_index do |question, index|
        q_text = question["question"]
        answer = state.answers[q_text]
        "Question #{index + 1}: #{q_text}\nAnswer: #{answer}"
      end.join("\n\n")

      { tool_use_id: state.tool_use_id, answer_text: answers }
    end
  end
end
