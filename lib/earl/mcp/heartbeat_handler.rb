# frozen_string_literal: true

require "yaml"
require "fileutils"

module Earl
  module Mcp
    # MCP handler exposing a manage_heartbeat tool to create, update, delete,
    # and list heartbeat schedules. Writes changes to the heartbeats YAML file;
    # the HeartbeatScheduler auto-reloads when it detects file changes.
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    # :reek:TooManyMethods :reek:RepeatedConditional
    class HeartbeatHandler
      TOOL_NAMES = %w[manage_heartbeat].freeze
      CONFIG_PATH = File.expand_path("~/.config/earl/heartbeats.yml")

      VALID_ACTIONS = %w[list create update delete].freeze
      MUTABLE_FIELDS = %w[description cron interval run_at channel_id working_dir
                          prompt permission_mode persistent timeout enabled once].freeze

      def initialize(default_channel_id: nil, config_path: CONFIG_PATH)
        @default_channel_id = default_channel_id
        @config_path = config_path
      end

      def tool_definitions
        [ manage_heartbeat_definition ]
      end

      # :reek:UtilityFunction
      def handles?(name)
        TOOL_NAMES.include?(name)
      end

      # :reek:ControlParameter
      def call(name, arguments)
        return unless name == "manage_heartbeat"

        action = arguments["action"]
        return text_content("Error: action is required (list, create, update, delete)") unless action
        return text_content("Error: unknown action '#{action}'. Valid: #{VALID_ACTIONS.join(', ')}") unless VALID_ACTIONS.include?(action)

        send("handle_#{action}", arguments)
      end

      private

      # --- Action handlers ---

      def handle_list(_arguments)
        data = load_yaml
        heartbeats = data["heartbeats"] || {}
        return text_content("No heartbeats defined.") if heartbeats.empty?

        lines = heartbeats.map { |name, config| format_heartbeat(name, config) }
        text_content("**Heartbeats (#{heartbeats.size}):**\n\n#{lines.join("\n\n")}")
      end

      # :reek:DuplicateMethodCall
      def handle_create(arguments)
        name = arguments["name"]
        return text_content("Error: name is required") unless name && !name.empty?

        data = load_yaml
        data["heartbeats"] ||= {}
        return text_content("Error: heartbeat '#{name}' already exists") if data["heartbeats"].key?(name)

        data["heartbeats"][name] = build_entry(arguments)
        save_yaml(data)
        text_content("Created heartbeat '#{name}'. Scheduler will pick it up within 30 seconds.")
      end

      # :reek:DuplicateMethodCall
      def handle_update(arguments)
        name = arguments["name"]
        return text_content("Error: name is required") unless name && !name.empty?

        data = load_yaml
        data["heartbeats"] ||= {}
        return text_content("Error: heartbeat '#{name}' not found") unless data["heartbeats"].key?(name)

        merge_entry(data["heartbeats"][name], arguments)
        save_yaml(data)
        text_content("Updated heartbeat '#{name}'. Scheduler will pick up changes within 30 seconds.")
      end

      # :reek:DuplicateMethodCall
      def handle_delete(arguments)
        name = arguments["name"]
        return text_content("Error: name is required") unless name && !name.empty?

        data = load_yaml
        data["heartbeats"] ||= {}
        return text_content("Error: heartbeat '#{name}' not found") unless data["heartbeats"].key?(name)

        data["heartbeats"].delete(name)
        save_yaml(data)
        text_content("Deleted heartbeat '#{name}'. Scheduler will remove it within 30 seconds.")
      end

      # --- YAML I/O ---

      def load_yaml
        return { "heartbeats" => {} } unless File.exist?(@config_path)

        data = YAML.safe_load_file(@config_path)
        data.is_a?(Hash) ? data : { "heartbeats" => {} }
      end

      def save_yaml(data)
        FileUtils.mkdir_p(File.dirname(@config_path))
        # Use file lock to coordinate with HeartbeatScheduler#disable_heartbeat
        File.open(@config_path, File::CREAT | File::WRONLY | File::TRUNC) do |file|
          file.flock(File::LOCK_EX)
          file.write(YAML.dump(data))
        end
      end

      # --- Entry building ---

      # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:TooManyStatements
      def build_entry(arguments)
        entry = {}
        entry["description"] = arguments["description"] if arguments["description"]
        entry["once"] = arguments["once"] if arguments.key?("once")
        entry["schedule"] = build_schedule(arguments)

        # Auto-set run_at for immediate one-offs (once: true with no schedule)
        if arguments["once"] && entry["schedule"].empty?
          entry["schedule"]["run_at"] = Time.now.to_i
        end

        entry["channel_id"] = arguments["channel_id"] || @default_channel_id
        entry["working_dir"] = arguments["working_dir"] if arguments["working_dir"]
        entry["prompt"] = arguments["prompt"] if arguments["prompt"]
        entry["permission_mode"] = arguments["permission_mode"] if arguments["permission_mode"]
        entry["persistent"] = arguments["persistent"] if arguments.key?("persistent")
        entry["timeout"] = arguments["timeout"] if arguments["timeout"]
        entry["enabled"] = arguments.fetch("enabled", true)
        entry
      end

      # :reek:DuplicateMethodCall
      def build_schedule(arguments)
        schedule = {}
        schedule["cron"] = arguments["cron"] if arguments["cron"]
        schedule["interval"] = arguments["interval"] if arguments["interval"]
        schedule["run_at"] = arguments["run_at"] if arguments["run_at"]
        schedule
      end

      # :reek:DuplicateMethodCall :reek:TooManyStatements
      def merge_entry(entry, arguments)
        MUTABLE_FIELDS.each do |field|
          next unless arguments.key?(field)

          case field
          when "cron"
            entry["schedule"] ||= {}
            entry["schedule"]["cron"] = arguments["cron"]
          when "interval"
            entry["schedule"] ||= {}
            entry["schedule"]["interval"] = arguments["interval"]
          when "run_at"
            entry["schedule"] ||= {}
            entry["schedule"]["run_at"] = arguments["run_at"]
          else
            entry[field] = arguments[field]
          end
        end
      end

      # --- Formatting ---

      # :reek:FeatureEnvy :reek:DuplicateMethodCall
      def format_heartbeat(name, config)
        schedule = config["schedule"] || {}
        schedule_str = format_schedule(schedule)
        enabled = config.fetch("enabled", true) ? "enabled" : "disabled"
        once_badge = config.fetch("once", false) ? ", once" : ""
        "- **#{name}** (#{enabled}#{once_badge}, #{schedule_str})\n  #{config['description'] || name}"
      end

      # :reek:DuplicateMethodCall :reek:UtilityFunction
      def format_schedule(schedule)
        if schedule["cron"]
          "cron: `#{schedule['cron']}`"
        elsif schedule["interval"]
          "interval: #{schedule['interval']}s"
        elsif schedule["run_at"]
          "run_at: #{Time.at(schedule['run_at']).strftime('%Y-%m-%d %H:%M:%S')}"
        else
          "no schedule"
        end
      end

      # --- MCP response helper ---

      def text_content(text)
        { content: [ { type: "text", text: text } ] }
      end

      # --- Tool definition ---

      # :reek:UtilityFunction
      def manage_heartbeat_definition
        {
          name: "manage_heartbeat",
          description: "Manage Earl's heartbeat schedules. " \
                       "Create, update, delete, or list tasks that run on cron, interval, or one-shot (run_at) schedules.",
          inputSchema: {
            type: "object",
            properties: {
              action: {
                type: "string",
                enum: VALID_ACTIONS,
                description: "Action to perform: list, create, update, or delete"
              },
              name: {
                type: "string",
                description: "Heartbeat name (required for create/update/delete)"
              },
              description: {
                type: "string",
                description: "Human-readable description of the heartbeat"
              },
              cron: {
                type: "string",
                description: "Cron expression (e.g. '0 9 * * 1-5' for weekdays at 9am)"
              },
              interval: {
                type: "integer",
                description: "Interval in seconds between runs (alternative to cron)"
              },
              channel_id: {
                type: "string",
                description: "Mattermost channel ID to post results (defaults to current channel)"
              },
              working_dir: {
                type: "string",
                description: "Working directory for the Claude session"
              },
              prompt: {
                type: "string",
                description: "The prompt to send to Claude when the heartbeat fires"
              },
              permission_mode: {
                type: "string",
                enum: %w[auto interactive],
                description: "Permission mode: auto (no approval) or interactive (requires reaction approval)"
              },
              persistent: {
                type: "boolean",
                description: "Whether to reuse the same Claude session across runs"
              },
              timeout: {
                type: "integer",
                description: "Maximum seconds to wait for completion (default: 600)"
              },
              enabled: {
                type: "boolean",
                description: "Whether the heartbeat is active (default: true)"
              },
              once: {
                type: "boolean",
                description: "Run once then auto-disable. Combine with run_at for scheduled one-shots, or omit schedule to fire immediately."
              },
              run_at: {
                type: "integer",
                description: "Unix timestamp (seconds since epoch) for one-shot execution (alternative to cron/interval). Must be used with once: true to avoid repeated firing."
              }
            },
            required: %w[action]
          }
        }
      end
    end
  end
end
