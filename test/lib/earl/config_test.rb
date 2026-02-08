require "test_helper"

class Earl::ConfigTest < ActiveSupport::TestCase
  setup do
    @original_env = ENV.to_h.slice(
      "MATTERMOST_URL", "MATTERMOST_BOT_TOKEN", "MATTERMOST_BOT_ID",
      "EARL_CHANNEL_ID", "EARL_ALLOWED_USERS"
    )

    ENV["MATTERMOST_URL"] = "https://mattermost.example.com"
    ENV["MATTERMOST_BOT_TOKEN"] = "test-token-123"
    ENV["MATTERMOST_BOT_ID"] = "bot-id-456"
    ENV["EARL_CHANNEL_ID"] = "channel-789"
    ENV["EARL_ALLOWED_USERS"] = "alice, bob, charlie"
  end

  teardown do
    %w[MATTERMOST_URL MATTERMOST_BOT_TOKEN MATTERMOST_BOT_ID EARL_CHANNEL_ID EARL_ALLOWED_USERS].each do |key|
      if @original_env.key?(key)
        ENV[key] = @original_env[key]
      else
        ENV.delete(key)
      end
    end
  end

  test "reads required env vars" do
    config = Earl::Config.new

    assert_equal "https://mattermost.example.com", config.mattermost_url
    assert_equal "test-token-123", config.bot_token
    assert_equal "bot-id-456", config.bot_id
    assert_equal "channel-789", config.channel_id
  end

  test "raises on missing required env var" do
    ENV.delete("MATTERMOST_URL")

    error = assert_raises(RuntimeError) { Earl::Config.new }
    assert_match(/Missing required env var: MATTERMOST_URL/, error.message)
  end

  test "parses allowed users from comma-separated list" do
    config = Earl::Config.new

    assert_equal %w[alice bob charlie], config.allowed_users
  end

  test "returns empty array when EARL_ALLOWED_USERS is not set" do
    ENV.delete("EARL_ALLOWED_USERS")
    config = Earl::Config.new

    assert_equal [], config.allowed_users
  end

  test "websocket_url converts https to wss" do
    config = Earl::Config.new

    assert_equal "wss://mattermost.example.com:443/api/v4/websocket", config.websocket_url
  end

  test "websocket_url converts http to ws" do
    ENV["MATTERMOST_URL"] = "http://localhost:8065"
    config = Earl::Config.new

    assert_equal "ws://localhost:8065/api/v4/websocket", config.websocket_url
  end

  test "api_url builds full API path" do
    config = Earl::Config.new

    assert_equal "https://mattermost.example.com/api/v4/posts", config.api_url("/posts")
    assert_equal "https://mattermost.example.com/api/v4/users/me/typing", config.api_url("/users/me/typing")
  end
end
