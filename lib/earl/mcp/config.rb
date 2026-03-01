# frozen_string_literal: true

module Earl
  module Mcp
    # Reads MCP permission server configuration from environment variables,
    # set by the parent EARL process when spawning Claude with --permission-prompt-tool.
    class Config
      attr_reader :allowed_users, :permission_timeout_ms, :pearl_skip_approval

      # Groups platform connection fields into a single struct.
      PlatformConnection = Data.define(:url, :token, :channel_id, :thread_id, :bot_id)

      def initialize
        @platform = PlatformConnection.new(
          url: required_env("PLATFORM_URL"),
          token: required_env("PLATFORM_TOKEN"),
          channel_id: required_env("PLATFORM_CHANNEL_ID"),
          thread_id: required_env("PLATFORM_THREAD_ID"),
          bot_id: required_env("PLATFORM_BOT_ID")
        )
        @allowed_users = ENV.fetch("ALLOWED_USERS", "").split(",").map(&:strip)
        @permission_timeout_ms = ENV.fetch("PERMISSION_TIMEOUT_MS", "86400000").to_i
        @pearl_skip_approval = ENV.fetch("PEARL_SKIP_APPROVAL", "false").downcase == "true"
      end

      def platform_url = @platform.url
      def platform_token = @platform.token
      def platform_channel_id = @platform.channel_id
      def platform_thread_id = @platform.thread_id
      def platform_bot_id = @platform.bot_id

      def api_url(path)
        "#{platform_url}/api/v4#{path}"
      end

      def websocket_url
        "#{platform_url.sub(%r{^https://}, "wss://").sub(%r{^http://}, "ws://")}/api/v4/websocket"
      end

      # Build a Config-like object compatible with ApiClient
      def to_api_config
        ApiConfig.new(
          mattermost_url: platform_url,
          bot_token: platform_token,
          bot_id: platform_bot_id
        )
      end

      # Minimal config struct compatible with ApiClient, built from platform env vars.
      ApiConfig = Struct.new(:mattermost_url, :bot_token, :bot_id, keyword_init: true) do
        def api_url(path)
          "#{mattermost_url}/api/v4#{path}"
        end
      end

      private

      def required_env(key)
        ENV.fetch(key) { raise "Missing required env var: #{key}" }
      end
    end
  end
end
