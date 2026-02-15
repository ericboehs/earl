# frozen_string_literal: true

module Earl
  # Handles AskUserQuestion tool_use events from Claude by posting numbered
  # options to Mattermost and collecting answers via emoji reactions.
  class QuestionHandler
    include Logging

    EMOJI_NUMBERS = %w[one two three four].freeze
    EMOJI_MAP = { "one" => 0, "two" => 1, "three" => 2, "four" => 3 }.freeze

    QuestionState = Struct.new(:tool_use_id, :questions, :answers, :current_index,
                               :current_post_id, :thread_id, :channel_id, keyword_init: true)

    def initialize(mattermost:)
      @mattermost = mattermost
      @pending_questions = {} # post_id -> QuestionState
      @mutex = Mutex.new
    end

    # :reek:TooManyStatements
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

      answer_index = EMOJI_MAP[emoji_name]
      return nil unless answer_index

      question = state.questions[state.current_index]
      options = question["options"] || []
      return nil unless answer_index < options.size

      record_answer(state, question, options[answer_index])
      @mutex.synchronize { @pending_questions.delete(post_id) }
      delete_question_post(post_id)

      state.current_index += 1

      if state.current_index < state.questions.size
        post_current_question(state)
        nil
      else
        build_answer_json(state)
      end
    end

    private

    # :reek:FeatureEnvy
    def post_current_question(state)
      question = state.questions[state.current_index]
      options = question["options"] || []

      lines = [ ":question: **#{question['question']}**" ]
      options.each_with_index do |opt, i|
        emoji = EMOJI_NUMBERS[i]
        label = opt["label"] || opt.to_s
        desc = opt["description"]
        lines << ":#{emoji}: #{label}#{desc ? " — #{desc}" : ''}"
      end

      result = @mattermost.create_post(
        channel_id: state.channel_id,
        message: lines.join("\n"),
        root_id: state.thread_id
      )

      post_id = result["id"]
      if post_id
        state.current_post_id = post_id
        add_emoji_options(post_id, options.size)
        @mutex.synchronize { @pending_questions[post_id] = state }
        true
      else
        false
      end
    end

    def add_emoji_options(post_id, count)
      count.times do |i|
        @mattermost.add_reaction(post_id: post_id, emoji_name: EMOJI_NUMBERS[i])
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
      answers = state.questions.map.with_index do |q, i|
        answer = state.answers[q["question"]]
        "Question #{i + 1}: #{q['question']}\nAnswer: #{answer}"
      end.join("\n\n")

      { tool_use_id: state.tool_use_id, answer_text: answers }
    end
  end
end
