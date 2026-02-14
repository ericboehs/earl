# frozen_string_literal: true

require "test_helper"

class Earl::HeartbeatConfigTest < ActiveSupport::TestCase
  FIXTURE_DIR = File.expand_path("fixtures/heartbeats", __dir__)

  setup do
    Earl.logger = Logger.new(File::NULL)
  end

  teardown do
    Earl.logger = nil
  end

  test "loads valid heartbeat definitions" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "valid.yml"))
    defs = config.definitions

    assert_equal 2, defs.size
    assert_equal "morning_briefing", defs[0].name
    assert_equal "Morning briefing for Eric", defs[0].description
    assert_equal "0 9 * * 1-5", defs[0].cron
    assert_nil defs[0].interval
    assert_equal "abc123def456", defs[0].channel_id
    assert_equal "/tmp", defs[0].working_dir
    assert_includes defs[0].prompt, "Summarize"
    assert_equal :auto, defs[0].permission_mode
    assert_equal false, defs[0].persistent
    assert_equal 300, defs[0].timeout

    assert_equal "repo_health", defs[1].name
    assert_equal 604_800, defs[1].interval
    assert_nil defs[1].cron
    assert_equal :interactive, defs[1].permission_mode
  end

  test "returns empty array for missing file" do
    config = Earl::HeartbeatConfig.new(path: "/nonexistent/heartbeats.yml")
    assert_equal [], config.definitions
  end

  test "returns empty array for malformed YAML" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "malformed.yml"))
    assert_equal [], config.definitions
  end

  test "filters out heartbeats without schedule" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "no_schedule.yml"))
    assert_equal [], config.definitions
  end

  test "filters out disabled heartbeats" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "disabled.yml"))
    defs = config.definitions

    assert_equal 1, defs.size
    assert_equal "enabled_beat", defs[0].name
  end

  test "expands tilde in working_dir" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "tilde.yml"))
    defs = config.definitions

    assert_equal 1, defs.size
    assert_not_includes defs[0].working_dir, "~"
    assert defs[0].working_dir.start_with?("/")
  end

  test "defaults permission_mode to interactive" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "valid.yml"))
    repo_health = config.definitions.find { |d| d.name == "repo_health" }
    assert_equal :interactive, repo_health.permission_mode
  end

  test "defaults timeout to 600" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "disabled.yml"))
    enabled = config.definitions.first
    assert_equal 600, enabled.timeout
  end

  test "defaults persistent to false" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "disabled.yml"))
    enabled = config.definitions.first
    assert_equal false, enabled.persistent
  end

  test "filters out heartbeats missing channel_id or prompt" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "missing_required.yml"))
    defs = config.definitions
    assert_equal [], defs
  end

  test "filters out non-hash heartbeat configs" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "missing_required.yml"))
    defs = config.definitions
    # "not_a_hash" is a string value, should be filtered
    names = defs.map(&:name)
    assert_not_includes names, "not_a_hash"
  end

  test "returns empty array when heartbeats key is not a hash" do
    config = Earl::HeartbeatConfig.new(path: File.join(FIXTURE_DIR, "bad_structure.yml"))
    assert_equal [], config.definitions
  end
end
