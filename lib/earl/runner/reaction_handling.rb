# frozen_string_literal: true

module Earl
  class Runner
    # Emoji reaction handling: routes reactions to question handler or tmux monitor.
    module ReactionHandling
      private

      def setup_reaction_handler
        @services.mattermost.on_reaction do |user_id:, post_id:, emoji_name:|
          handle_reaction(user_id: user_id, post_id: post_id, emoji_name: emoji_name)
        end
      end

      def handle_reaction(user_id:, post_id:, emoji_name:)
        return unless allowed_reactor?(user_id)

        result = @services.question_handler.handle_reaction(post_id: post_id, emoji_name: emoji_name)
        if result
          thread_id = @responses.question_threads[result[:tool_use_id]]
          return unless thread_id

          session = @services.session_manager.get(thread_id)
          session&.send_message(result[:answer_text])
          return
        end

        @services.tmux_monitor.handle_reaction(post_id: post_id, emoji_name: emoji_name)
      end

      def allowed_reactor?(user_id)
        allowed = @services.config.allowed_users
        return true if allowed.empty?

        username = @services.mattermost.get_user(user_id: user_id)["username"]
        return false unless username

        allowed.include?(username)
      end
    end
  end
end
