# frozen_string_literal: true

module Earl
  class TmuxMonitor
    # Builds and posts state-change alerts (error, completed, stalled, tombstone)
    # to Mattermost. Interactive states (questions, permissions) are delegated
    # to the appropriate forwarder instead.
    module AlertDispatcher
      # Bundles session identity and captured output for alert message building.
      AlertContext = Data.define(:name, :output)

      private

      def dispatch_state_alert(state, **context)
        name, output, info = context.values_at(:name, :output, :info)
        forwarder = { asking_question: @deps.question_forwarder,
                      requesting_permission: @deps.permission_forwarder }[state]
        if forwarder
          forwarder.forward(name, output, info)
        else
          msg = passive_alert_message(state, AlertContext.new(name: name, output: output))
          post_alert(info, msg) if msg
        end
      end

      def passive_alert_message(state, ctx)
        { errored: error_message(ctx),
          completed: completed_message(ctx),
          stalled: stalled_message(ctx.name) }[state]
      end

      def error_message(ctx)
        ":x: Session `#{ctx.name}` encountered an error:\n```\n#{ctx.output.lines.last(10)&.join}\n```"
      end

      def completed_message(ctx)
        name, output = ctx.deconstruct_keys(%i[name output]).values_at(:name, :output)
        response = OutputAnalyzer.extract_last_response(output)
        base = ":white_check_mark: `#{name}` idle"
        response ? "#{base}\n> #{truncate_response(response)}" : base
      end

      def truncate_response(text, max = 500)
        text.length > max ? "#{text[0...max]}..." : text
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
