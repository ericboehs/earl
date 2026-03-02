# frozen_string_literal: true

require "yaml"
require "fileutils"

module Earl
  module Cli
    # CLI handler for `earl heartbeat` subcommands.
    # Reuses YamlPersistence, EntryBuilder, and Formatting from HeartbeatHandler.
    class Heartbeat
      include Mcp::HeartbeatHandler::YamlPersistence
      include Mcp::HeartbeatHandler::EntryBuilder
      include Mcp::HeartbeatHandler::Formatting

      ACTIONS = %w[list create update delete].freeze
      BOOLEAN_FLAGS = %w[persistent once enabled].freeze
      INTEGER_FLAGS = %w[interval run_at timeout].freeze

      def self.run(argv)
        new.run(argv)
      end

      def initialize(config_path: Mcp::HeartbeatHandler.config_path, default_channel_id: nil)
        @config_path = config_path
        @default_channel_id = default_channel_id
      end

      def run(argv)
        action = argv[0]
        unless ACTIONS.include?(action)
          warn "Usage: earl heartbeat <list|create|update|delete> [options]"
          exit 1
        end

        send("handle_#{action}", FlagParser.parse(argv.drop(1)))
      end

      private

      def handle_list(_flags)
        data = load_yaml
        heartbeats = data["heartbeats"] || {}
        if heartbeats.empty?
          puts "No heartbeats defined."
          return
        end

        puts "Heartbeats (#{heartbeats.size}):\n\n"
        heartbeats.each { |name, config| puts "#{format_heartbeat(name, config)}\n\n" }
      end

      def handle_create(flags)
        name = require_flag(flags, "name")
        data = load_yaml
        heartbeats = (data["heartbeats"] ||= {})

        if heartbeats.key?(name)
          warn "Error: heartbeat '#{name}' already exists"
          exit 1
        end

        heartbeats[name] = build_entry(flags)
        save_yaml(data)
        puts "Created heartbeat '#{name}'."
      end

      def handle_update(flags)
        name = require_flag(flags, "name")
        data = load_yaml
        entry = find_heartbeat(data, name)

        merge_entry(entry, flags)
        save_yaml(data)
        puts "Updated heartbeat '#{name}'."
      end

      def find_heartbeat(data, name)
        heartbeats = (data["heartbeats"] ||= {})
        entry = heartbeats[name]
        return entry if entry

        warn "Error: heartbeat '#{name}' not found"
        exit 1
      end

      def handle_delete(flags)
        name = require_flag(flags, "name")
        data = load_yaml
        heartbeats = (data["heartbeats"] ||= {})
        removed = heartbeats.delete(name)

        unless removed
          warn "Error: heartbeat '#{name}' not found"
          exit 1
        end

        save_yaml(data)
        puts "Deleted heartbeat '#{name}'."
      end

      def require_flag(flags, key)
        value = flags.fetch(key, "")
        if value.to_s.empty?
          warn "Error: --#{key} is required"
          exit 1
        end
        value
      end

      # Parses --flag value pairs from ARGV into a hash.
      # Boolean flags (--persistent, --once, --enabled) are bare when no value follows.
      # Hyphenated flags are normalized to underscores; short aliases are expanded.
      module FlagParser
        ALIASES = { "channel" => "channel_id", "working-dir" => "working_dir",
                    "permission-mode" => "permission_mode" }.freeze

        def self.parse(argv)
          tokens = argv.dup
          flags = {}
          consume_tokens(tokens, flags) until tokens.empty?
          flags
        end

        def self.consume_tokens(tokens, flags)
          key = extract_key(tokens)
          return unless key

          flags[key] = bare_boolean?(key, tokens) || coerce_value(key, tokens.shift)
        end

        def self.extract_key(tokens)
          token = tokens.shift
          return unless token.start_with?("--")

          raw = token.delete_prefix("--")
          ALIASES.fetch(raw, raw)
        end

        def self.bare_boolean?(key, remaining)
          return false unless BOOLEAN_FLAGS.include?(key)

          remaining.empty? || remaining.first.start_with?("--")
        end

        def self.coerce_value(key, value)
          return value.to_i if INTEGER_FLAGS.include?(key)
          return value == "true" if BOOLEAN_FLAGS.include?(key)

          value
        end
      end
    end
  end
end
