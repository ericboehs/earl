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

    # :reek:UtilityFunction :reek:ControlParameter :reek:TooManyStatements
    def extract_tool_detail_from(tool_name, input)
      input ||= {}
      case tool_name
      when "Bash" then input["command"]
      when "Read", "Edit", "Write" then input["file_path"]
      when "WebFetch" then input["url"]
      when "WebSearch" then input["query"]
      when "Grep", "Glob" then input["pattern"]
      else
        compact = input.compact
        compact.empty? ? nil : JSON.generate(compact)
      end
    end
  end
end
