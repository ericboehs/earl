# frozen_string_literal: true

module Earl
  class TmuxMonitor
    # Handles forwarding detected permission prompts from tmux panes to Mattermost
    # and processing user reactions (approve/deny) back as tmux keyboard input.
    class PermissionForwarder
      include Logging

      PERMISSION_EMOJIS = { "white_check_mark" => "y", "x" => "n" }.freeze

      def initialize(mattermost:, tmux:, pending_interactions:, mutex:)
        @mattermost = mattermost
        @tmux = tmux
        @pending_interactions = pending_interactions
        @mutex = mutex
      end

      def forward(name, output, info)
        post = post_permission(name, output, info)
        return unless post

        register_interaction(post, name)
      end

      def handle_reaction(interaction, emoji_name, post_id)
        answer = PERMISSION_EMOJIS[emoji_name]
        return nil unless answer

        send_answer(interaction, answer, post_id)
      end

      private

      def send_answer(interaction, answer, post_id)
        @tmux.send_keys(interaction[:session_name], answer)
        @mutex.synchronize { @pending_interactions.delete(post_id) }
        true
      rescue Tmux::Error => error
        log(:error, "TmuxMonitor: failed to send permission answer: #{error.message}")
        nil
      end

      def post_permission(name, output, info)
        context = output.lines.last(15)&.join || ""
        message = build_permission_message(name, context)
        @mattermost.create_post(
          channel_id: info.channel_id,
          message: message,
          root_id: info.thread_id
        )
      rescue StandardError => error
        log(:error, "TmuxMonitor: failed to post alert (#{error.class}): #{error.message}")
        nil
      end

      def build_permission_message(name, context)
        [
          ":lock: **Tmux `#{name}`** is requesting permission:",
          "```",
          context,
          "```",
          ":white_check_mark: Approve  |  :x: Deny"
        ].join("\n")
      end

      def register_interaction(post, name)
        post_id = post["id"]
        return unless post_id

        @mattermost.add_reaction(post_id: post_id, emoji_name: "white_check_mark")
        @mattermost.add_reaction(post_id: post_id, emoji_name: "x")

        @mutex.synchronize do
          @pending_interactions[post_id] = { session_name: name, type: :permission }
        end
      end
    end
  end
end
