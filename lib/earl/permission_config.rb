# frozen_string_literal: true

module Earl
  # Shared permission configuration builder for MCP permission server.
  # Used by both SessionManager (user-initiated) and HeartbeatScheduler (automated).
  module PermissionConfig
    private

    def build_permission_env(config, channel_id:, thread_id: "")
      return nil if config.skip_permissions?

      {
        "PLATFORM_URL" => config.mattermost_url,
        "PLATFORM_TOKEN" => config.bot_token,
        "PLATFORM_CHANNEL_ID" => channel_id,
        "PLATFORM_THREAD_ID" => thread_id,
        "PLATFORM_BOT_ID" => config.bot_id,
        "ALLOWED_USERS" => config.allowed_users.join(",")
      }
    end
  end
end
