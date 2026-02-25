# frozen_string_literal: true

module Earl
  class ClaudeSession
    # Tracks usage statistics, timing, and cost across the session.
    Stats = Struct.new(
      :total_cost, :total_input_tokens, :total_output_tokens,
      :turn_input_tokens, :turn_output_tokens,
      :cache_read_tokens, :cache_creation_tokens,
      :context_window, :model_id,
      :message_sent_at, :first_token_at, :complete_at,
      keyword_init: true
    ) do
      def time_to_first_token
        return nil unless message_sent_at && first_token_at

        first_token_at - message_sent_at
      end

      def tokens_per_second
        return nil unless first_token_at && complete_at && turn_output_tokens&.positive?

        duration = complete_at - first_token_at
        return nil unless duration.positive?

        turn_output_tokens / duration
      end

      def context_percent
        return nil unless context_window&.positive?

        context_tokens = turn_input_tokens + cache_read_tokens + cache_creation_tokens
        return nil unless context_tokens.positive?

        (context_tokens.to_f / context_window * 100)
      end

      def reset_turn
        self.turn_input_tokens = 0
        self.turn_output_tokens = 0
        self.cache_read_tokens = 0
        self.cache_creation_tokens = 0
        self.message_sent_at = nil
        self.first_token_at = nil
        self.complete_at = nil
      end

      def begin_turn
        reset_turn
        self.message_sent_at = Time.now
      end

      def format_summary(prefix)
        parts = ["#{prefix}:", format_token_stats, *format_timing_stats]
        parts << "model=#{model_id}" if model_id
        parts.join(" | ")
      end

      def format_token_stats
        total = total_input_tokens + total_output_tokens
        "#{total} tokens (turn: in:#{turn_input_tokens} out:#{turn_output_tokens})"
      end

      def format_timing_stats
        parts = []
        pct = context_percent
        parts << format("%.0f%% context", pct) if pct
        ttft = time_to_first_token
        parts << format("TTFT: %.1fs", ttft) if ttft
        tps = tokens_per_second
        parts << format("%.0f tok/s", tps) if tps
        parts
      end
    end
  end
end
