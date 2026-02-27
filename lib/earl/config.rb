# frozen_string_literal: true

module Earl
  # Holds and validates environment-based configuration for Mattermost
  # connectivity, bot credentials, and channel targeting.
  class Config
    # Groups Mattermost server URL and bot authentication credentials.
    MattermostCredentials = Struct.new(:url, :bot_token, :bot_id, keyword_init: true)

    attr_reader :credentials, :channel_id, :allowed_users, :skip_permissions

    alias skip_permissions? skip_permissions

    def initialize
      @credentials = build_credentials
      @channel_id = required_env("EARL_CHANNEL_ID")
      @allowed_users = ENV.fetch("EARL_ALLOWED_USERS", "").split(",").map(&:strip)
      @skip_permissions = ENV.fetch("EARL_SKIP_PERMISSIONS", "false").downcase == "true"
    end

    def mattermost_url
      credentials.url
    end

    def bot_token
      credentials.bot_token
    end

    def bot_id
      credentials.bot_id
    end

    def websocket_url
      "#{mattermost_url.sub(%r{^https://}, "wss://").sub(%r{^http://}, "ws://")}/api/v4/websocket"
    end

    def api_url(path)
      "#{mattermost_url}/api/v4#{path}"
    end

    def channels
      @channels ||= parse_channels
    end

    # Builds the env hash for the MCP server subprocess.
    # Always returns the env hash — MCP tools are needed regardless
    # of whether permission prompts are skipped.
    def mcp_server_env(channel_id:, thread_id: "")
      url, token, bot_id = credentials.to_h.values_at(:url, :bot_token, :bot_id)
      {
        "PLATFORM_URL" => url, "PLATFORM_TOKEN" => token,
        "PLATFORM_CHANNEL_ID" => channel_id, "PLATFORM_THREAD_ID" => thread_id,
        "PLATFORM_BOT_ID" => bot_id, "ALLOWED_USERS" => allowed_users.join(",")
      }
    end

    # Builds a complete McpConfig for a Claude session, bundling env and permission mode.
    def build_mcp_config(channel_id:, thread_id: "")
      env = mcp_server_env(channel_id: channel_id, thread_id: thread_id)
      ClaudeSession::McpConfig.new(env: env, skip_permissions: skip_permissions?)
    end

    private

    def parse_channels
      default_dir = Dir.pwd
      return { channel_id => default_dir } unless ENV.key?("EARL_CHANNELS")

      entries = ENV.fetch("EARL_CHANNELS").split(",")
      return { channel_id => default_dir } if entries.empty?

      entries.each_with_object({}) do |entry, hash|
        channel, path = entry.strip.split(":", 2)
        hash[channel] = path || default_dir
      end
    end

    def build_credentials
      url = required_env("MATTERMOST_URL")
      validate_url(url)
      MattermostCredentials.new(
        url: url,
        bot_token: required_env("MATTERMOST_BOT_TOKEN"),
        bot_id: required_env("MATTERMOST_BOT_ID")
      )
    end

    def required_env(key)
      ENV.fetch(key) { raise "Missing required env var: #{key}" }
    end

    def validate_url(url)
      uri = URI.parse(url)
      raise "MATTERMOST_URL must be an HTTP(S) URL, got: #{url}" unless uri.is_a?(URI::HTTP)
    rescue URI::InvalidURIError
      raise "MATTERMOST_URL is not a valid URL: #{url}"
    end
  end
end
