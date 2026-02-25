# frozen_string_literal: true

module Earl
  class TmuxMonitor
    # Builds and posts state-change alerts (error, completed, stalled, tombstone)
    # to Mattermost. Interactive states (questions, permissions) are delegated
    # to the appropriate forwarder instead.
    module AlertDispatcher
      private

      def dispatch_state_alert(state, **context)
        name, output, info = context.values_at(:name, :output, :info)
        forwarder = { asking_question: @deps.question_forwarder,
                      requesting_permission: @deps.permission_forwarder }[state]
        if forwarder
          forwarder.forward(name, output, info)
        else
          msg = passive_alert_message(state, name, output)
          post_alert(info, msg) if msg
        end
      end

      def passive_alert_message(state, name, output)
        { errored: error_message(name, output),
          completed: completed_message(name),
          stalled: stalled_message(name) }[state]
      end

      def error_message(name, output)
        ":x: Session `#{name}` encountered an error:\n```\n#{output.lines.last(10)&.join}\n```"
      end

      def completed_message(name)
        ":white_check_mark: Session `#{name}` appears to have completed (shell prompt detected)."
      end

      def stalled_message(name)
        ":hourglass: Session `#{name}` appears stalled (output unchanged for #{@poll_state.stall_threshold} polls)."
      end

      def post_alert(info, message)
        @deps.mattermost.create_post(
          channel_id: info.channel_id,
          message: message,
          root_id: info.thread_id
        )
      rescue StandardError => error
        log(:error, "TmuxMonitor: failed to post alert (#{error.class}): #{error.message}")
        nil
      end
    end
  end
end
