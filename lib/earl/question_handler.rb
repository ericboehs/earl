# frozen_string_literal: true

module Earl
  # Handles AskUserQuestion tool_use events from Claude by posting numbered
  # options to Mattermost and collecting answers via emoji reactions.
  class QuestionHandler
    include Logging

    EMOJI_NUMBERS = %w[one two three four].freeze
    EMOJI_MAP = { "one" => 0, "two" => 1, "three" => 2, "four" => 3 }.freeze

    # Tracks in-progress question flow: which tool_use triggered it, the list of
    # questions, collected answers, and the Mattermost post/thread IDs.
    QuestionState = Struct.new(:tool_use_id, :questions, :answers, :current_index,
                               :current_post_id, :thread_id, :channel_id, keyword_init: true)

    def initialize(mattermost:)
      @mattermost = mattermost
      @pending_questions = {} # post_id -> QuestionState
      @mutex = Mutex.new
    end

    def handle_tool_use(thread_id:, tool_use:, channel_id: nil)
      return nil unless tool_use[:name] == "AskUserQuestion"

      input = tool_use[:input]
      questions = input["questions"] || []
      return nil if questions.empty?

      tool_use_id = tool_use[:id]
      state = QuestionState.new(
        tool_use_id: tool_use_id,
        questions: questions,
        answers: {},
        current_index: 0,
        thread_id: thread_id,
        channel_id: channel_id
      )

      unless post_current_question(state)
        log(:error, "Failed to post question for tool_use #{tool_use_id}, returning error answer")
        return { tool_use_id: tool_use_id, answer_text: "Failed to post question to chat" }
      end

      { tool_use_id: tool_use_id }
    end

    def handle_reaction(post_id:, emoji_name:)
      state = @mutex.synchronize { @pending_questions[post_id] }
      return nil unless state

      questions = state.questions
      index = state.current_index
      selected = resolve_selected_option(state, emoji_name)
      return nil unless selected

      record_answer(state, questions[index], selected)
      @mutex.synchronize { @pending_questions.delete(post_id) }
      delete_question_post(post_id)

      state.current_index = index + 1
      if state.current_index < questions.size
        post_current_question(state)
        nil
      else
        build_answer_json(state)
      end
    end

    private

    def post_current_question(state)
      question = state.questions[state.current_index]
      message = build_question_message(question)

      result = @mattermost.create_post(channel_id: state.channel_id, message: message, root_id: state.thread_id)
      register_question_post(state, result["id"], (question["options"] || []).size)
    end

    def resolve_selected_option(state, emoji_name)
      answer_index = EMOJI_MAP[emoji_name]
      return nil unless answer_index

      options = state.questions[state.current_index]["options"] || []
      answer_index < options.size ? options[answer_index] : nil
    end

    def build_question_message(question)
      options = question["options"] || []
      lines = [ ":question: **#{question['question']}**" ]
      options.each_with_index do |opt, index|
        emoji = EMOJI_NUMBERS[index]
        label = opt["label"] || opt.to_s
        desc = opt["description"]
        lines << ":#{emoji}: #{label}#{desc ? " — #{desc}" : ''}"
      end
      lines.join("\n")
    end

    def register_question_post(state, post_id, option_count)
      if post_id
        state.current_post_id = post_id
        add_emoji_options(post_id, option_count)
        @mutex.synchronize { @pending_questions[post_id] = state }
        true
      else
        false
      end
    end

    def add_emoji_options(post_id, count)
      count.times do |index|
        @mattermost.add_reaction(post_id: post_id, emoji_name: EMOJI_NUMBERS[index])
      end
    end

    def delete_question_post(post_id)
      @mattermost.delete_post(post_id: post_id)
    rescue StandardError => error
      log(:warn, "Failed to delete question post #{post_id}: #{error.message}")
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
