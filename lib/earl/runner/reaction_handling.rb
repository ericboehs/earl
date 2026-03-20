# frozen_string_literal: true

module Earl
  class Runner
    # Emoji reaction handling: routes reactions to question handler, tmux monitor, or Claude session.
    module ReactionHandling
      # Bundles reaction event data that travels together through routing.
      ReactionEvent = Data.define(:post_id, :emoji_name)

      # Emoji reactions that control session lifecycle instead of being forwarded.
      SESSION_CONTROL_EMOJIS = {
        "octagonal_sign" => :stop,
        "skull" => :kill,
        "warning" => :escape
      }.freeze

      private

      def setup_reaction_handler
        @services.mattermost.on_reaction do |user_id:, post_id:, emoji_name:|
          handle_reaction(user_id: user_id, post_id: post_id, emoji_name: emoji_name)
        end
      end

      def handle_reaction(user_id:, post_id:, emoji_name:)
        return unless allowed_reactor?(user_id)

        event = ReactionEvent.new(post_id: post_id, emoji_name: emoji_name)
        return if handle_question_reaction(event)
        return if @services.tmux_monitor.handle_reaction(post_id: post_id, emoji_name: emoji_name)
        return if handle_session_control_reaction(event)

        forward_reaction_to_session(event)
      end

      def handle_question_reaction(event)
        result = @services.question_handler.handle_reaction(post_id: event.post_id, emoji_name: event.emoji_name)
        return unless result

        thread_id = @responses.question_threads[result[:tool_use_id]]
        return unless thread_id

        session = @services.session_manager.get(thread_id)
        session&.send_message(result[:answer_text])
      end

      def handle_session_control_reaction(event)
        action = SESSION_CONTROL_EMOJIS[event.emoji_name]
        return unless action

        thread_id, = resolve_bot_post(event.post_id)
        return unless thread_id

        execute_session_control(action, thread_id)
        true
      end

      def execute_session_control(action, thread_id)
        thread_tag = thread_id[0..7]
        acted = send(:"reaction_#{action}", thread_id)
        log(:info, "Session #{action} via :#{SESSION_CONTROL_EMOJIS.key(action)}: on thread #{thread_tag}") if acted
      rescue Errno::ESRCH
        log(:info, "Process already exited for thread #{thread_tag}")
        @services.session_manager.stop_session(thread_id) if action == :kill
      end

      def reaction_stop(thread_id)
        @services.session_manager.stop_session(thread_id)
      end

      def reaction_kill(thread_id)
        session = @services.session_manager.get(thread_id)
        signal_and_stop_session("KILL", session, thread_id)
      end

      def reaction_escape(thread_id)
        session = @services.session_manager.get(thread_id)
        return unless session&.process_pid

        Process.kill("INT", session.process_pid)
      end

      def signal_and_stop_session(signal, session, thread_id)
        return unless session&.process_pid

        Process.kill(signal, session.process_pid)
        @services.session_manager.stop_session(thread_id)
      end

      def forward_reaction_to_session(event)
        thread_id, channel_id = resolve_bot_post(event.post_id)
        return unless thread_id
        return unless @services.session_manager.get(thread_id)

        emoji = event.emoji_name
        log(:info, "Forwarding :#{emoji}: reaction to thread #{thread_id[0..7]}")
        msg = UserMessage.new(thread_id: thread_id, channel_id: channel_id, sender_name: nil,
                              text: "[The user reacted with :#{emoji}: to your message]")
        enqueue_message(msg)
      end

      def resolve_bot_post(post_id)
        post = @services.mattermost.get_post(post_id: post_id)
        return if post.empty?

        user_id, root_id, pid, channel_id = post.values_at("user_id", "root_id", "id", "channel_id")
        return unless user_id == @services.config.bot_id

        [root_id.to_s.empty? ? pid : root_id, channel_id]
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
