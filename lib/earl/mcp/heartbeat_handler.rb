# frozen_string_literal: true

require "yaml"
require "fileutils"

module Earl
  module Mcp
    # MCP handler exposing a manage_heartbeat tool to create, update, delete,
    # and list heartbeat schedules. Writes changes to the heartbeats YAML file;
    # the HeartbeatScheduler auto-reloads when it detects file changes.
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class HeartbeatHandler
      include HandlerBase

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

      NAME_REQUIRED_ACTIONS = %w[create update delete].freeze

      def call(name, arguments)
        return unless handles?(name)

        action = arguments["action"]
        return text_content("Error: action is required (list, create, update, delete)") unless action
        return text_content("Error: unknown action '#{action}'. Valid: #{VALID_ACTIONS.join(', ')}") unless VALID_ACTIONS.include?(action)

        if NAME_REQUIRED_ACTIONS.include?(action)
          hb_name = arguments["name"]
          return text_content("Error: name is required") unless hb_name && !hb_name.empty?
        end

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

      def handle_create(arguments)
        name = arguments["name"]
        data = load_yaml
        heartbeats = (data["heartbeats"] ||= {})
        return text_content("Error: heartbeat '#{name}' already exists") if heartbeats.key?(name)

        heartbeats[name] = build_entry(arguments)
        save_yaml(data)
        text_content("Created heartbeat '#{name}'. Scheduler will pick it up within 30 seconds.")
      end

      def handle_update(arguments)
        name = arguments["name"]
        data = load_yaml
        heartbeats = (data["heartbeats"] ||= {})
        entry = heartbeats.fetch(name, nil)
        return text_content("Error: heartbeat '#{name}' not found") unless entry

        merge_entry(entry, arguments)
        save_yaml(data)
        text_content("Updated heartbeat '#{name}'. Scheduler will pick up changes within 30 seconds.")
      end

      def handle_delete(arguments)
        name = arguments["name"]
        data = load_yaml
        heartbeats = (data["heartbeats"] ||= {})
        removed = heartbeats.delete(name)
        return text_content("Error: heartbeat '#{name}' not found") unless removed

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

      # Entry building: constructs and merges heartbeat configuration hashes.
      module EntryBuilder
        OPTIONAL_STRING_KEYS = %w[working_dir prompt permission_mode timeout].freeze
        SCHEDULE_KEYS = %w[cron interval run_at].freeze

        private

        def build_entry(arguments)
          schedule = slice_present(arguments, SCHEDULE_KEYS)
          schedule["run_at"] = Time.now.to_i if arguments["once"] && schedule.empty?

          base = slice_present(arguments, %w[description once])
          base.merge(
            "schedule" => schedule,
            "channel_id" => arguments["channel_id"] || @default_channel_id,
            "enabled" => arguments.fetch("enabled", true)
          ).merge(slice_present(arguments, OPTIONAL_STRING_KEYS))
            .merge(slice_key(arguments, "persistent"))
        end

        def slice_present(hash, keys)
          keys.each_with_object({}) do |key, result|
            result[key] = hash[key] if hash.key?(key)
          end
        end

        def slice_key(hash, key)
          hash.key?(key) ? { key => hash[key] } : {}
        end

        def merge_entry(entry, arguments)
          schedule = (entry["schedule"] ||= {})
          MUTABLE_FIELDS.each do |field|
            next unless arguments.key?(field)

            value = arguments[field]
            target = SCHEDULE_KEYS.include?(field) ? schedule : entry
            target[field] = value
          end
        end

        def build_schedule(arguments)
          slice_present(arguments, SCHEDULE_KEYS)
        end
      end

      include EntryBuilder

      # --- Formatting ---

      def format_heartbeat(name, config)
        schedule, enabled, once, description = extract_display_fields(config, name)
        schedule_str = format_schedule(schedule)
        enabled_str = enabled ? "enabled" : "disabled"
        once_badge = once ? ", once" : ""
        "- **#{name}** (#{enabled_str}#{once_badge}, #{schedule_str})\n  #{description}"
      end

      def extract_display_fields(config, name)
        [
          config["schedule"] || {},
          config.fetch("enabled", true),
          config.fetch("once", false),
          config["description"] || name
        ]
      end

      def format_schedule(schedule)
        cron = schedule["cron"]
        interval = schedule["interval"]
        run_at = schedule["run_at"]

        if cron
          "cron: `#{cron}`"
        elsif interval
          "interval: #{interval}s"
        elsif run_at
          "run_at: #{Time.at(run_at).strftime('%Y-%m-%d %H:%M:%S')}"
        else
          "no schedule"
        end
      end

      # --- MCP response helper ---

      def text_content(text)
        { content: [ { type: "text", text: text } ] }
      end

      # --- Tool definition ---

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
