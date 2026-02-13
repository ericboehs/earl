require "test_helper"

class Earl::ConfigTest < ActiveSupport::TestCase
  setup do
    @original_env = ENV.to_h.slice(
      "MATTERMOST_URL", "MATTERMOST_BOT_TOKEN", "MATTERMOST_BOT_ID",
      "EARL_CHANNEL_ID", "EARL_ALLOWED_USERS", "EARL_SKIP_PERMISSIONS", "EARL_CHANNELS"
    )

    ENV["MATTERMOST_URL"] = "https://mattermost.example.com"
    ENV["MATTERMOST_BOT_TOKEN"] = "test-token-123"
    ENV["MATTERMOST_BOT_ID"] = "bot-id-456"
    ENV["EARL_CHANNEL_ID"] = "channel-789"
    ENV["EARL_ALLOWED_USERS"] = "alice, bob, charlie"
  end

  teardown do
    %w[MATTERMOST_URL MATTERMOST_BOT_TOKEN MATTERMOST_BOT_ID EARL_CHANNEL_ID EARL_ALLOWED_USERS EARL_SKIP_PERMISSIONS EARL_CHANNELS].each do |key|
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

    assert_equal "wss://mattermost.example.com/api/v4/websocket", config.websocket_url
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

  test "raises on non-HTTP URL" do
    ENV["MATTERMOST_URL"] = "ftp://mattermost.example.com"

    error = assert_raises(RuntimeError) { Earl::Config.new }
    assert_match(/must be an HTTP/, error.message)
  end

  test "raises on invalid URL" do
    ENV["MATTERMOST_URL"] = "not a url at all %%"

    error = assert_raises(RuntimeError) { Earl::Config.new }
    assert_match(/not a valid URL/, error.message)
  end

  # --- skip_permissions? tests ---

  test "skip_permissions? returns false by default" do
    ENV.delete("EARL_SKIP_PERMISSIONS")
    config = Earl::Config.new
    assert_not config.skip_permissions?
  end

  test "skip_permissions? returns true when set" do
    ENV["EARL_SKIP_PERMISSIONS"] = "true"
    config = Earl::Config.new
    assert config.skip_permissions?
  end

  test "skip_permissions? is case insensitive" do
    ENV["EARL_SKIP_PERMISSIONS"] = "TRUE"
    config = Earl::Config.new
    assert config.skip_permissions?
  end

  test "skip_permissions? returns false for non-true values" do
    ENV["EARL_SKIP_PERMISSIONS"] = "yes"
    config = Earl::Config.new
    assert_not config.skip_permissions?
  end

  # --- channels tests ---

  test "channels returns default channel with cwd when EARL_CHANNELS not set" do
    ENV.delete("EARL_CHANNELS")
    config = Earl::Config.new

    channels = config.channels
    assert_equal 1, channels.size
    assert_equal Dir.pwd, channels["channel-789"]
  end

  test "channels parses EARL_CHANNELS with paths" do
    ENV["EARL_CHANNELS"] = "ch-1:/tmp/project1,ch-2:/tmp/project2"
    config = Earl::Config.new

    channels = config.channels
    assert_equal 2, channels.size
    assert_equal "/tmp/project1", channels["ch-1"]
    assert_equal "/tmp/project2", channels["ch-2"]
  end

  test "channels defaults path to cwd for entries without path" do
    ENV["EARL_CHANNELS"] = "ch-1"
    config = Earl::Config.new

    channels = config.channels
    assert_equal Dir.pwd, channels["ch-1"]
  end
end
