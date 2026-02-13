# frozen_string_literal: true

module Earl
  module Mcp
    # Reads MCP permission server configuration from environment variables,
    # set by the parent EARL process when spawning Claude with --permission-prompt-tool.
    class Config
      attr_reader :platform_url, :platform_token, :platform_channel_id,
                  :platform_thread_id, :platform_bot_id, :allowed_users,
                  :permission_timeout_ms

      def initialize
        @platform_url = required_env("PLATFORM_URL")
        @platform_token = required_env("PLATFORM_TOKEN")
        @platform_channel_id = required_env("PLATFORM_CHANNEL_ID")
        @platform_thread_id = required_env("PLATFORM_THREAD_ID")
        @platform_bot_id = required_env("PLATFORM_BOT_ID")
        @allowed_users = ENV.fetch("ALLOWED_USERS", "").split(",").map(&:strip)
        @permission_timeout_ms = ENV.fetch("PERMISSION_TIMEOUT_MS", "120000").to_i
      end

      def api_url(path)
        "#{platform_url}/api/v4#{path}"
      end

      def websocket_url
        platform_url.sub(%r{^https://}, "wss://").sub(%r{^http://}, "ws://") + "/api/v4/websocket"
      end

      # Build a Config-like object compatible with ApiClient
      def to_api_config
        ApiConfig.new(
          mattermost_url: platform_url,
          bot_token: platform_token,
          bot_id: platform_bot_id
        )
      end

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
