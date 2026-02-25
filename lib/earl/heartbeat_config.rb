# frozen_string_literal: true

require "yaml"

module Earl
  # Loads and validates heartbeat definitions from <config_root>/heartbeats.yml.
  class HeartbeatConfig
    include Logging

    def self.config_path
      @config_path ||= File.join(Earl.config_root, "heartbeats.yml")
    end

    attr_reader :path

    # A single heartbeat definition with schedule, prompt, and execution options.
    HeartbeatDefinition = Struct.new(
      :name, :description, :cron, :interval, :run_at, :channel_id, :working_dir,
      :prompt, :permission_mode, :persistent, :timeout, :enabled, :once,
      keyword_init: true
    ) do
      def self.from_config(name, config, working_dir_resolver)
        schedule = config["schedule"] || {}
        new(
          name: name, description: config["description"] || name,
          cron: schedule["cron"], interval: schedule["interval"], run_at: schedule["run_at"],
          **extract_options(config, working_dir_resolver)
        )
      end

      def self.extract_options(config, working_dir_resolver)
        {
          channel_id: config["channel_id"],
          working_dir: working_dir_resolver.call(config["working_dir"]),
          prompt: config["prompt"],
          permission_mode: (config["permission_mode"] || "interactive").to_sym,
          persistent: config.fetch("persistent", false),
          timeout: config.fetch("timeout", 600),
          enabled: config.fetch("enabled", true),
          once: config.fetch("once", false)
        }
      end

      def active?
        enabled && channel_id && prompt
      end

      def auto_permission?
        permission_mode == :auto
      end

      def base_session_opts
        { working_dir: working_dir, auto_permission: auto_permission?, channel_id: channel_id }
      end
    end

    def initialize(path: self.class.config_path)
      @path = path
    end

    def definitions
      load_definitions
    rescue StandardError => error
      log(:warn, "Failed to load heartbeat config from #{@path}: #{error.message}")
      []
    end

    private

    def load_definitions
      return [] unless File.exist?(@path)

      data = YAML.safe_load_file(@path)
      heartbeats = data.is_a?(Hash) ? data["heartbeats"] : nil
      return [] unless heartbeats.is_a?(Hash)

      heartbeats.filter_map { |name, config| build_definition(name, config) }
    end

    def build_definition(name, config)
      return nil unless config.is_a?(Hash)
      return nil unless valid_schedule?(config)

      definition = HeartbeatDefinition.from_config(name, config, method(:resolve_working_dir))
      definition if definition.active?
    end

    def valid_schedule?(config)
      schedule = config["schedule"]
      return false unless schedule.is_a?(Hash)

      schedule.key?("cron") || schedule.key?("interval") || schedule.key?("run_at")
    end

    def resolve_working_dir(path)
      return nil unless path

      File.expand_path(path)
    end
  end
end
