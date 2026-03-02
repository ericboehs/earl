# frozen_string_literal: true

require "test_helper"

module Earl
  module Cli
    class HeartbeatTest < Minitest::Test
      setup do
        @tmp_dir = Dir.mktmpdir("earl-cli-heartbeat-test")
        @config_path = File.join(@tmp_dir, "heartbeats.yml")
      end

      teardown do
        FileUtils.rm_rf(@tmp_dir)
      end

      # --- list ---

      test "list prints message when no heartbeats exist" do
        output = run_cli("list")
        assert_includes output, "No heartbeats defined"
      end

      test "list prints formatted heartbeats" do
        write_heartbeats(
          "daily_standup" => {
            "description" => "Daily standup reminder",
            "schedule" => { "cron" => "0 9 * * 1-5" },
            "channel_id" => "ch-123",
            "enabled" => true
          }
        )

        output = run_cli("list")
        assert_includes output, "Heartbeats (1)"
        assert_includes output, "daily_standup"
        assert_includes output, "cron: `0 9 * * 1-5`"
        assert_includes output, "Daily standup reminder"
      end

      # --- create ---

      test "create writes heartbeat to YAML" do
        run_cli("create", "--name", "test_beat", "--prompt", "hello", "--cron", "0 9 * * *")

        data = YAML.safe_load_file(@config_path)
        assert data["heartbeats"].key?("test_beat")
        assert_equal "0 9 * * *", data["heartbeats"]["test_beat"]["schedule"]["cron"]
        assert_equal "hello", data["heartbeats"]["test_beat"]["prompt"]
      end

      test "create prints confirmation" do
        output = run_cli("create", "--name", "test_beat", "--prompt", "hello", "--cron", "0 9 * * *")
        assert_includes output, "Created heartbeat 'test_beat'"
      end

      test "create with duplicate name exits with error" do
        write_heartbeats("existing" => { "schedule" => {}, "channel_id" => "ch", "prompt" => "p" })

        error = assert_raises(SystemExit) { run_cli("create", "--name", "existing", "--prompt", "hi") }
        assert_equal 1, error.status
      end

      test "create stores boolean flags" do
        run_cli("create", "--name", "beat", "--prompt", "hi", "--cron", "0 0 * * *", "--persistent", "--once")

        data = YAML.safe_load_file(@config_path)
        entry = data["heartbeats"]["beat"]
        assert_equal true, entry["persistent"]
        assert_equal true, entry["once"]
      end

      test "create stores integer flags" do
        run_cli("create", "--name", "beat", "--prompt", "hi", "--interval", "3600", "--timeout", "120")

        data = YAML.safe_load_file(@config_path)
        entry = data["heartbeats"]["beat"]
        assert_equal 3600, entry["schedule"]["interval"]
        assert_equal 120, entry["timeout"]
      end

      test "create with --enabled true stores boolean" do
        run_cli("create", "--name", "beat", "--prompt", "hi", "--cron", "0 0 * * *", "--enabled", "true")

        data = YAML.safe_load_file(@config_path)
        assert_equal true, data["heartbeats"]["beat"]["enabled"]
      end

      # --- update ---

      test "update modifies existing heartbeat" do
        write_heartbeats(
          "beat" => {
            "description" => "Old",
            "schedule" => { "cron" => "0 0 * * *" },
            "channel_id" => "ch",
            "prompt" => "old prompt"
          }
        )

        output = run_cli("update", "--name", "beat", "--prompt", "new prompt")
        assert_includes output, "Updated heartbeat 'beat'"

        data = YAML.safe_load_file(@config_path)
        assert_equal "new prompt", data["heartbeats"]["beat"]["prompt"]
        assert_equal "Old", data["heartbeats"]["beat"]["description"]
      end

      test "update nonexistent heartbeat exits with error" do
        error = assert_raises(SystemExit) { run_cli("update", "--name", "ghost", "--prompt", "hi") }
        assert_equal 1, error.status
      end

      # --- delete ---

      test "delete removes heartbeat from YAML" do
        write_heartbeats(
          "doomed" => { "schedule" => {}, "channel_id" => "ch", "prompt" => "p" },
          "keeper" => { "schedule" => {}, "channel_id" => "ch", "prompt" => "p" }
        )

        output = run_cli("delete", "--name", "doomed")
        assert_includes output, "Deleted heartbeat 'doomed'"

        data = YAML.safe_load_file(@config_path)
        assert_not data["heartbeats"].key?("doomed")
        assert data["heartbeats"].key?("keeper")
      end

      test "delete nonexistent heartbeat exits with error" do
        error = assert_raises(SystemExit) { run_cli("delete", "--name", "ghost") }
        assert_equal 1, error.status
      end

      # --- missing required flags ---

      test "create without --name exits with error" do
        error = assert_raises(SystemExit) { run_cli("create", "--prompt", "hi") }
        assert_equal 1, error.status
      end

      # --- flag parser edge cases ---

      test "flag parser ignores non-flag tokens" do
        run_cli("create", "--name", "beat", "--prompt", "hi", "stray_arg", "--cron", "0 0 * * *")

        data = YAML.safe_load_file(@config_path)
        assert data["heartbeats"].key?("beat")
        assert_equal "0 0 * * *", data["heartbeats"]["beat"]["schedule"]["cron"]
      end

      test "flag parser maps --channel alias to channel_id" do
        run_cli("create", "--name", "beat", "--prompt", "hi", "--channel", "ch-alias")

        data = YAML.safe_load_file(@config_path)
        assert_equal "ch-alias", data["heartbeats"]["beat"]["channel_id"]
      end

      test "flag parser normalizes hyphens to underscores" do
        run_cli("create", "--name", "beat", "--prompt", "hi", "--working-dir", "/tmp/test",
                "--permission-mode", "strict")

        data = YAML.safe_load_file(@config_path)
        entry = data["heartbeats"]["beat"]
        assert_equal "/tmp/test", entry["working_dir"]
        assert_equal "strict", entry["permission_mode"]
      end

      test "flag parser aborts on non-integer for integer flag" do
        error = assert_raises(SystemExit) { run_cli("create", "--name", "beat", "--interval", "abc") }
        assert_equal 1, error.status
      end

      test "flag parser aborts when non-boolean flag has no value" do
        error = assert_raises(SystemExit) { run_cli("create", "--name", "--prompt", "hi") }
        assert_equal 1, error.status
      end

      test "create with --enabled false stores false" do
        run_cli("create", "--name", "beat", "--prompt", "hi", "--cron", "0 0 * * *", "--enabled", "false")

        data = YAML.safe_load_file(@config_path)
        assert_equal false, data["heartbeats"]["beat"]["enabled"]
      end

      # --- invalid action ---

      test "unknown action exits with error" do
        error = assert_raises(SystemExit) { run_cli("explode") }
        assert_equal 1, error.status
      end

      # --- round-trip with HeartbeatConfig ---

      test "created YAML is loadable by HeartbeatConfig" do
        run_cli("create", "--name", "roundtrip", "--prompt", "Test", "--cron", "0 9 * * 1-5",
                "--channel", "ch-999")

        config = Earl::HeartbeatConfig.new(path: @config_path)
        defs = config.definitions
        assert_equal 1, defs.size
        assert_equal "roundtrip", defs.first.name
        assert_equal "0 9 * * 1-5", defs.first.cron
      end

      private

      def run_cli(*args)
        cli = Earl::Cli::Heartbeat.new(config_path: @config_path)
        capture_io { cli.run(args) }.first
      end

      def write_heartbeats(heartbeats)
        File.write(@config_path, YAML.dump("heartbeats" => heartbeats))
      end
    end
  end
end
