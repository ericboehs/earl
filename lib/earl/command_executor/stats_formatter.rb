# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Formats session statistics for the !stats command.
    module StatsFormatter
      private

      def format_stats(stats)
        total_in = stats.total_input_tokens
        total_out = stats.total_output_tokens
        lines = [ "#### :bar_chart: Session Stats", "| Metric | Value |", "|--------|-------|" ]
        lines << "| **Total tokens** | #{format_number(total_in + total_out)} (in: #{format_number(total_in)}, out: #{format_number(total_out)}) |"
        append_optional_stats(lines, stats)
        lines << "| **Cost** | $#{format('%.4f', stats.total_cost)} |"
        lines.join("\n")
      end

      def append_optional_stats(lines, stats)
        append_context_stat(lines, stats)
        append_model_stat(lines, stats)
        append_ttft_stat(lines, stats)
        append_speed_stat(lines, stats)
      end

      def append_context_stat(lines, stats)
        pct = stats.context_percent
        return unless pct

        lines << "| **Context used** | #{format('%.1f%%', pct)} of #{format_number(stats.context_window)} |"
      end

      def append_model_stat(lines, stats)
        model = stats.model_id
        return unless model

        lines << "| **Model** | `#{model}` |"
      end

      def append_ttft_stat(lines, stats)
        ttft = stats.time_to_first_token
        return unless ttft

        lines << "| **Last TTFT** | #{format('%.1fs', ttft)} |"
      end

      def append_speed_stat(lines, stats)
        tps = stats.tokens_per_second
        return unless tps

        lines << "| **Last speed** | #{format('%.0f', tps)} tok/s |"
      end

      def format_persisted_stats(persisted)
        total_in = persisted.total_input_tokens || 0
        total_out = persisted.total_output_tokens || 0
        lines = [ "#### :bar_chart: Session Stats (stopped)", "| Metric | Value |", "|--------|-------|" ]
        lines << "| **Total tokens** | #{format_number(total_in + total_out)} (in: #{format_number(total_in)}, out: #{format_number(total_out)}) |"
        lines << "| **Cost** | $#{format('%.4f', persisted.total_cost)} |"
        lines.join("\n")
      end
    end
  end
end
