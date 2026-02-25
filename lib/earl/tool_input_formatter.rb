# frozen_string_literal: true

module Earl
  # Shared tool input formatting for display in Mattermost posts and permission requests.
  module ToolInputFormatter
    TOOL_ICONS = {
      "Bash" => "🔧", "Read" => "📖", "Edit" => "✏️", "Write" => "📝",
      "WebFetch" => "🌐", "WebSearch" => "🌐", "Glob" => "🔍", "Grep" => "🔍",
      "Task" => "👥", "AskUserQuestion" => "❓"
    }.freeze

    def format_tool_display(tool_name, input)
      icon = TOOL_ICONS.fetch(tool_name, "⚙️")
      detail = extract_tool_detail_from(tool_name, input)

      if detail
        "#{icon} `#{tool_name}`\n```\n#{detail}\n```"
      else
        "#{icon} `#{tool_name}`"
      end
    end

    private

    def extract_tool_detail_from(tool_name, input)
      key = TOOL_DETAIL_KEYS[tool_name]
      key ? input&.dig(key) : summarize_input(input)
    end

    TOOL_DETAIL_KEYS = {
      "Bash" => "command", "Read" => "file_path", "Edit" => "file_path",
      "Write" => "file_path", "WebFetch" => "url", "WebSearch" => "query",
      "Grep" => "pattern", "Glob" => "pattern"
    }.freeze
    private_constant :TOOL_DETAIL_KEYS

    def summarize_input(input)
      return nil unless input

      entries = input.to_h.compact
      entries.empty? ? nil : JSON.generate(entries)
    end
  end
end
