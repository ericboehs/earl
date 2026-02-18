require "test_helper"

class Earl::Mcp::ConfigTest < ActiveSupport::TestCase
  setup do
    @original_env = ENV.to_h.slice(
      "PLATFORM_URL", "PLATFORM_TOKEN", "PLATFORM_CHANNEL_ID",
      "PLATFORM_THREAD_ID", "PLATFORM_BOT_ID", "ALLOWED_USERS",
      "PERMISSION_TIMEOUT_MS"
    )

    ENV["PLATFORM_URL"] = "https://mattermost.example.com"
    ENV["PLATFORM_TOKEN"] = "test-token"
    ENV["PLATFORM_CHANNEL_ID"] = "channel-1"
    ENV["PLATFORM_THREAD_ID"] = "thread-1"
    ENV["PLATFORM_BOT_ID"] = "bot-1"
    ENV["ALLOWED_USERS"] = "alice,bob"
    ENV["PERMISSION_TIMEOUT_MS"] = "5000"
  end

  teardown do
    %w[PLATFORM_URL PLATFORM_TOKEN PLATFORM_CHANNEL_ID PLATFORM_THREAD_ID PLATFORM_BOT_ID ALLOWED_USERS PERMISSION_TIMEOUT_MS].each do |key|
      if @original_env.key?(key)
        ENV[key] = @original_env[key]
      else
        ENV.delete(key)
      end
    end
  end

  test "reads all required env vars" do
    config = Earl::Mcp::Config.new

    assert_equal "https://mattermost.example.com", config.platform_url
    assert_equal "test-token", config.platform_token
    assert_equal "channel-1", config.platform_channel_id
    assert_equal "thread-1", config.platform_thread_id
    assert_equal "bot-1", config.platform_bot_id
  end

  test "parses allowed users" do
    config = Earl::Mcp::Config.new
    assert_equal %w[alice bob], config.allowed_users
  end

  test "parses permission timeout" do
    config = Earl::Mcp::Config.new
    assert_equal 5000, config.permission_timeout_ms
  end

  test "defaults timeout to 86400000" do
    ENV.delete("PERMISSION_TIMEOUT_MS")
    config = Earl::Mcp::Config.new
    assert_equal 86_400_000, config.permission_timeout_ms
  end

  test "api_url builds full API path" do
    config = Earl::Mcp::Config.new
    assert_equal "https://mattermost.example.com/api/v4/posts", config.api_url("/posts")
  end

  test "websocket_url converts https to wss" do
    config = Earl::Mcp::Config.new
    assert_equal "wss://mattermost.example.com/api/v4/websocket", config.websocket_url
  end

  test "to_api_config returns compatible struct" do
    config = Earl::Mcp::Config.new
    api_config = config.to_api_config

    assert_equal "https://mattermost.example.com", api_config.mattermost_url
    assert_equal "test-token", api_config.bot_token
    assert_equal "bot-1", api_config.bot_id
    assert_equal "https://mattermost.example.com/api/v4/posts", api_config.api_url("/posts")
  end

  test "raises on missing required env var" do
    ENV.delete("PLATFORM_URL")

    error = assert_raises(RuntimeError) { Earl::Mcp::Config.new }
    assert_match(/Missing required env var: PLATFORM_URL/, error.message)
  end

  test "defaults allowed_users to empty" do
    ENV.delete("ALLOWED_USERS")
    config = Earl::Mcp::Config.new
    assert_equal [], config.allowed_users
  end
end
