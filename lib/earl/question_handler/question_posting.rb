# frozen_string_literal: true

module Earl
  class QuestionHandler
    # Handles building question messages, posting them, and managing reactions.
    module QuestionPosting
      private

      def post_current_question(state)
        question = state.current_question
        message = build_question_message(question)

        post_id = create_question_post(state.channel_id, state.thread_id, message)
        register_question_post(state, post_id, (question["options"] || []).size)
      end

      def create_question_post(channel_id, thread_id, message)
        result = @mattermost.create_post(channel_id: channel_id, message: message, root_id: thread_id)
        result["id"]
      end

      def build_question_message(question)
        options = question["options"] || []
        lines = [":question: **#{question["question"]}**"]
        options.each_with_index do |opt, index|
          emoji = EMOJI_NUMBERS[index]
          label = opt["label"] || opt.to_s
          desc = opt["description"]
          lines << ":#{emoji}: #{label}#{" — #{desc}" if desc}"
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
    end
  end
end
