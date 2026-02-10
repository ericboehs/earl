# frozen_string_literal: true

module Earl
  # Holds and validates environment-based configuration for Mattermost
  # connectivity, bot credentials, and channel targeting.
  # :reek:TooManyInstanceVariables
  class Config
    attr_reader :mattermost_url, :bot_token, :bot_id, :channel_id, :allowed_users

    def initialize
      @mattermost_url = required_env("MATTERMOST_URL")
      validate_url(@mattermost_url)
      @bot_token      = required_env("MATTERMOST_BOT_TOKEN")
      @bot_id         = required_env("MATTERMOST_BOT_ID")
      @channel_id     = required_env("EARL_CHANNEL_ID")
      @allowed_users  = ENV.fetch("EARL_ALLOWED_USERS", "").split(",").map(&:strip)
    end

    # :reek:FeatureEnvy
    def websocket_url
      uri = URI.parse(@mattermost_url)
      scheme = uri.scheme == "https" ? "wss" : "ws"
      "#{scheme}://#{uri.host}:#{uri.port}/api/v4/websocket"
    end

    def api_url(path)
      "#{@mattermost_url}/api/v4#{path}"
    end

    private

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
