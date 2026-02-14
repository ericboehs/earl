# frozen_string_literal: true

require "yaml"

module Earl
  # Loads and validates heartbeat definitions from ~/.config/earl/heartbeats.yml.
  class HeartbeatConfig
    include Logging

    CONFIG_PATH = File.expand_path("~/.config/earl/heartbeats.yml")

    # A single heartbeat definition with schedule, prompt, and execution options.
    HeartbeatDefinition = Struct.new(
      :name, :description, :cron, :interval, :channel_id, :working_dir,
      :prompt, :permission_mode, :persistent, :timeout, :enabled,
      keyword_init: true
    )

    def initialize(path: CONFIG_PATH)
      @path = path
    end

    def definitions
      load_definitions
    rescue StandardError => error
      log(:warn, "Failed to load heartbeat config from #{@path}: #{error.message}")
      []
    end

    private

    # :reek:DuplicateMethodCall
    def load_definitions
      return [] unless File.exist?(@path)

      data = YAML.safe_load_file(@path)
      return [] unless data.is_a?(Hash) && data["heartbeats"].is_a?(Hash)

      data["heartbeats"].filter_map { |name, config| build_definition(name, config) }
    end

    # :reek:FeatureEnvy :reek:DuplicateMethodCall
    def build_definition(name, config)
      return nil unless config.is_a?(Hash)
      return nil unless valid_schedule?(config)

      definition = HeartbeatDefinition.new(
        name: name,
        description: config["description"] || name,
        cron: config.dig("schedule", "cron"),
        interval: config.dig("schedule", "interval"),
        channel_id: config["channel_id"],
        working_dir: resolve_working_dir(config["working_dir"]),
        prompt: config["prompt"],
        permission_mode: (config["permission_mode"] || "interactive").to_sym,
        persistent: config.fetch("persistent", false),
        timeout: config.fetch("timeout", 600),
        enabled: config.fetch("enabled", true)
      )

      return nil unless definition.enabled
      return nil unless definition.channel_id && definition.prompt

      definition
    end

    def valid_schedule?(config)
      schedule = config["schedule"]
      return false unless schedule.is_a?(Hash)

      schedule.key?("cron") || schedule.key?("interval")
    end

    def resolve_working_dir(path)
      return nil unless path

      File.expand_path(path)
    end
  end
end
