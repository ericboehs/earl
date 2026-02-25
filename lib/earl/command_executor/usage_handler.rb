# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Handles !usage and !context commands — fetches external data
    # via background threads and posts formatted results.
    module UsageHandler
      CONTEXT_CATEGORIES = {
        "messages" => "Messages", "system_prompt" => "System prompt",
        "system_tools" => "System tools", "custom_agents" => "Custom agents",
        "memory_files" => "Memory files", "skills" => "Skills",
        "free_space" => "Free space", "autocompact_buffer" => "Autocompact buffer"
      }.freeze

      private

      def handle_usage(ctx)
        reply(ctx, ":hourglass: Fetching usage data (takes ~15s)...")
        run_usage_fetch(ctx)
      end

      def run_usage_fetch(ctx)
        Thread.new { usage_fetch_body(ctx) }
      end

      def usage_fetch_body(ctx)
        data = fetch_usage_data
        message = data ? format_usage(data) : ":x: Failed to fetch usage data."
        reply(ctx, message)
      rescue StandardError => error
        msg = error.message
        log(:error, "Usage command error: #{msg}")
        reply(ctx, ":x: Error fetching usage: #{msg}")
      end

      def fetch_usage_data
        output, status = Open3.capture2(USAGE_SCRIPT, "--json", err: File::NULL)
        return nil unless status.success?

        JSON.parse(output)
      rescue JSON::ParserError
        nil
      end

      def format_usage(data)
        lines = ["#### :bar_chart: Claude Usage"]
        append_usage_section(lines, data["session"], "Session")
        append_usage_section(lines, data["week"], "Week")
        append_usage_section(lines, data["sonnet_week"], "Sonnet")
        append_usage_extra(lines, data["extra"])
        lines.join("\n")
      end

      def append_usage_section(lines, section, label)
        return unless section&.dig("percent_used")

        lines << "- **#{label}:** #{section["percent_used"]}% used \u2014 resets #{section["resets"]}"
      end

      def append_usage_extra(lines, extra)
        return unless extra&.dig("percent_used")

        pct, spent, budget, resets = extra.values_at("percent_used", "spent", "budget", "resets")
        lines << "- **Extra:** #{pct}% used (#{spent} / #{budget}) \u2014 resets #{resets}"
      end

      def handle_context(ctx)
        sid = @deps.session_manager.claude_session_id_for(ctx.thread_id)
        unless sid
          reply(ctx, "No session found for this thread.")
          return
        end

        reply(ctx, ":hourglass: Fetching context data (takes ~20s)...")
        run_context_fetch(ctx, sid)
      end

      def run_context_fetch(ctx, sid)
        Thread.new { context_fetch_body(ctx, sid) }
      end

      def context_fetch_body(ctx, sid)
        data = fetch_context_data(sid)
        message = data ? format_context(data) : ":x: Failed to fetch context data."
        reply(ctx, message)
      rescue StandardError => error
        msg = error.message
        log(:error, "Context command error: #{msg}")
        reply(ctx, ":x: Error fetching context: #{msg}")
      end

      def fetch_context_data(session_id)
        output, status = Open3.capture2(CONTEXT_SCRIPT, session_id, "--json", err: File::NULL)
        return nil unless status.success?

        JSON.parse(output)
      rescue JSON::ParserError
        nil
      end

      def format_context(data)
        model, used, total, pct, cats = data.values_at("model", "used_tokens", "total_tokens", "percent_used",
                                                       "categories")
        lines = [
          "#### :brain: Context Window Usage",
          "- **Model:** `#{model}`",
          "- **Used:** #{used} / #{total} tokens (#{pct})"
        ]
        append_context_categories(lines, cats)
        lines.join("\n")
      end

      def append_context_categories(lines, cats)
        return unless cats

        lines << ""
        CONTEXT_CATEGORIES.each do |key, label|
          append_category_line(lines, cats[key], label)
        end
      end

      def append_category_line(lines, cat, label)
        tokens = cat&.fetch("tokens", nil)
        return unless tokens

        pct_val = cat["percent"]
        pct = pct_val ? " (#{pct_val})" : ""
        lines << "- **#{label}:** #{tokens} tokens#{pct}"
      end
    end
  end
end
