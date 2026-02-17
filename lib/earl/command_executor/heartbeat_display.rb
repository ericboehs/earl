# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Formats and displays heartbeat schedule status for the !heartbeats command.
    module HeartbeatDisplay
      private

      def handle_heartbeats(ctx)
        unless @deps.heartbeat_scheduler
          return reply(ctx, "Heartbeat scheduler not configured.")
        end

        statuses = @deps.heartbeat_scheduler.status
        return reply(ctx, "No heartbeats configured.") if statuses.empty?

        reply(ctx, format_heartbeats(statuses))
      end

      def format_heartbeats(statuses)
        header = [
          "#### \u{1FAC0} Heartbeat Status",
          "| Name | Next Run | Last Run | Runs | Status |",
          "|------|----------|----------|------|--------|"
        ]
        rows = statuses.map { |entry| format_heartbeat_row(entry) }
        (header + rows).join("\n")
      end

      def format_heartbeat_row(status)
        name, run_count, next_at, last_at = status.values_at(:name, :run_count, :next_run_at, :last_run_at)
        next_run = format_time(next_at)
        last_run = format_time(last_at)
        state = heartbeat_status_label(status)
        "| #{name} | #{next_run} | #{last_run} | #{run_count} | #{state} |"
      end

      def heartbeat_status_label(status)
        if status[:running]
          "\u{1F7E2} Running"
        elsif status[:last_error]
          "\u{1F534} Error"
        else
          "\u26AA Idle"
        end
      end

      def format_time(time)
        return "\u2014" unless time

        time.strftime("%Y-%m-%d %H:%M")
      end
    end
  end
end
