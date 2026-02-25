# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Formats session statistics for the !stats command.
    module StatsFormatter
      private

      def format_stats(stats)
        total_in = stats.total_input_tokens
        total_out = stats.total_output_tokens
        cost = stats.total_cost
        header = ["#### :bar_chart: Session Stats", "| Metric | Value |", "|--------|-------|"]
        rows = [format_token_row(total_in, total_out)]
        append_optional_stats(rows, stats)
        rows << format_cost_row(cost)
        (header + rows).join("\n")
      end

      def append_optional_stats(lines, stats)
        append_context_line(lines, stats)
        append_model_line(lines, stats.model_id)
        append_ttft_line(lines, stats.time_to_first_token)
        append_speed_line(lines, stats.tokens_per_second)
      end

      def append_context_line(lines, stats)
        pct = stats.context_percent
        return unless pct

        lines << "| **Context used** | #{format("%.1f%%", pct)} of #{format_number(stats.context_window)} |"
      end

      def append_model_line(lines, model)
        lines << "| **Model** | `#{model}` |" if model
      end

      def append_ttft_line(lines, ttft)
        lines << "| **Last TTFT** | #{format("%.1fs", ttft)} |" if ttft
      end

      def append_speed_line(lines, tps)
        lines << "| **Last speed** | #{format("%.0f", tps)} tok/s |" if tps
      end

      def format_persisted_stats(persisted)
        total_in, total_out, cost = persisted.to_h.values_at(
          :total_input_tokens, :total_output_tokens, :total_cost
        )
        token_row = format_token_row(total_in || 0, total_out || 0)
        cost_row = format_cost_row(cost)
        ["#### :bar_chart: Session Stats (stopped)", "| Metric | Value |", "|--------|-------|",
         token_row, cost_row].join("\n")
      end

      def format_token_row(total_in, total_out)
        total = format_number(total_in + total_out)
        "| **Total tokens** | #{total} (in: #{format_number(total_in)}, out: #{format_number(total_out)}) |"
      end

      def format_cost_row(cost)
        "| **Cost** | $#{format("%.4f", cost)} |"
      end
    end
  end
end
