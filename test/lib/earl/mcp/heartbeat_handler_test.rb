# frozen_string_literal: true

require "test_helper"

module Earl
  module Mcp
    class HeartbeatHandlerTest < Minitest::Test
      setup do
        @tmp_dir = Dir.mktmpdir("earl-heartbeat-handler-test")
        @config_path = File.join(@tmp_dir, "heartbeats.yml")
        @handler = Earl::Mcp::HeartbeatHandler.new(
          default_channel_id: "default-channel-123",
          config_path: @config_path
        )
      end

      teardown do
        FileUtils.rm_rf(@tmp_dir)
      end

      # --- tool_definitions ---

      test "tool_definitions returns one tool" do
        defs = @handler.tool_definitions
        assert_equal 1, defs.size
        assert_equal "manage_heartbeat", defs.first[:name]
      end

      test "tool_definitions includes inputSchema with action as required" do
        schema = @handler.tool_definitions.first[:inputSchema]
        assert_equal "object", schema[:type]
        assert_includes schema[:required], "action"
      end

      # --- handles? ---

      test "handles? returns true for manage_heartbeat" do
        assert @handler.handles?("manage_heartbeat")
      end

      test "handles? returns false for other tools" do
        assert_not @handler.handles?("save_memory")
        assert_not @handler.handles?("permission_prompt")
      end

      # --- action validation ---

      test "call returns error when action is missing" do
        result = @handler.call("manage_heartbeat", {})
        text = result[:content].first[:text]
        assert_includes text, "Error: action is required"
      end

      test "call returns error for unknown action" do
        result = @handler.call("manage_heartbeat", { "action" => "explode" })
        text = result[:content].first[:text]
        assert_includes text, "unknown action 'explode'"
      end

      test "call returns nil for unhandled tool name" do
        result = @handler.call("other_tool", { "action" => "list" })
        assert_nil result
      end

      # --- list ---

      test "list returns message when no file exists" do
        result = @handler.call("manage_heartbeat", { "action" => "list" })
        text = result[:content].first[:text]
        assert_includes text, "No heartbeats defined"
      end

      test "list returns message when file has empty heartbeats" do
        File.write(@config_path, YAML.dump("heartbeats" => {}))
        result = @handler.call("manage_heartbeat", { "action" => "list" })
        text = result[:content].first[:text]
        assert_includes text, "No heartbeats defined"
      end

      test "list returns formatted heartbeat entries" do
        write_heartbeats(
          "daily_standup" => {
            "description" => "Daily standup reminder",
            "schedule" => { "cron" => "0 9 * * 1-5" },
            "channel_id" => "ch-123",
            "prompt" => "Remind about standup",
            "enabled" => true
          }
        )

        result = @handler.call("manage_heartbeat", { "action" => "list" })
        text = result[:content].first[:text]
        assert_includes text, "Heartbeats (1)"
        assert_includes text, "daily_standup"
        assert_includes text, "cron: `0 9 * * 1-5`"
        assert_includes text, "enabled"
        assert_includes text, "Daily standup reminder"
      end

      test "list shows interval schedule" do
        write_heartbeats(
          "health_check" => {
            "description" => "Health check",
            "schedule" => { "interval" => 3600 },
            "channel_id" => "ch-123",
            "prompt" => "Check health",
            "enabled" => true
          }
        )

        result = @handler.call("manage_heartbeat", { "action" => "list" })
        text = result[:content].first[:text]
        assert_includes text, "interval: 3600s"
      end

      test "list shows disabled status" do
        write_heartbeats(
          "disabled_beat" => {
            "description" => "Disabled",
            "schedule" => { "cron" => "0 0 * * *" },
            "channel_id" => "ch-123",
            "prompt" => "Noop",
            "enabled" => false
          }
        )

        result = @handler.call("manage_heartbeat", { "action" => "list" })
        text = result[:content].first[:text]
        assert_includes text, "disabled"
      end

      # --- create ---

      test "create succeeds with valid arguments" do
        result = @handler.call("manage_heartbeat", {
                                 "action" => "create",
                                 "name" => "daily_standup",
                                 "cron" => "0 9 * * 1-5",
                                 "prompt" => "Remind about standup",
                                 "description" => "Daily standup reminder"
                               })

        text = result[:content].first[:text]
        assert_includes text, "Created heartbeat 'daily_standup'"
        assert_includes text, "within 30 seconds"

        # Verify file was written
        data = YAML.safe_load_file(@config_path)
        assert data["heartbeats"].key?("daily_standup")
        assert_equal "0 9 * * 1-5", data["heartbeats"]["daily_standup"]["schedule"]["cron"]
        assert_equal "Remind about standup", data["heartbeats"]["daily_standup"]["prompt"]
      end

      test "create returns error when name is missing" do
        result = @handler.call("manage_heartbeat", { "action" => "create" })
        text = result[:content].first[:text]
        assert_includes text, "Error: name is required"
      end

      test "create returns error when name is empty" do
        result = @handler.call("manage_heartbeat", { "action" => "create", "name" => "" })
        text = result[:content].first[:text]
        assert_includes text, "Error: name is required"
      end

      test "create returns error for duplicate name" do
        write_heartbeats(
          "existing" => { "schedule" => { "cron" => "0 0 * * *" }, "channel_id" => "ch", "prompt" => "p" }
        )

        result = @handler.call("manage_heartbeat", {
                                 "action" => "create", "name" => "existing", "cron" => "0 9 * * *"
                               })

        text = result[:content].first[:text]
        assert_includes text, "already exists"
      end

      test "create uses default_channel_id when channel_id not provided" do
        @handler.call("manage_heartbeat", {
                        "action" => "create", "name" => "test_beat", "cron" => "0 9 * * *", "prompt" => "Test"
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal "default-channel-123", data["heartbeats"]["test_beat"]["channel_id"]
      end

      test "create uses provided channel_id over default" do
        @handler.call("manage_heartbeat", {
                        "action" => "create", "name" => "test_beat", "cron" => "0 9 * * *",
                        "prompt" => "Test", "channel_id" => "custom-channel"
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal "custom-channel", data["heartbeats"]["test_beat"]["channel_id"]
      end

      test "create stores interval schedule" do
        @handler.call("manage_heartbeat", {
                        "action" => "create", "name" => "interval_beat", "interval" => 3600, "prompt" => "Check"
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal 3600, data["heartbeats"]["interval_beat"]["schedule"]["interval"]
      end

      test "create stores all optional fields" do
        @handler.call("manage_heartbeat", {
                        "action" => "create",
                        "name" => "full_beat",
                        "cron" => "0 9 * * *",
                        "prompt" => "Full prompt",
                        "description" => "Full description",
                        "working_dir" => "/tmp/work",
                        "permission_mode" => "auto",
                        "persistent" => true,
                        "timeout" => 120,
                        "enabled" => false
                      })

        data = YAML.safe_load_file(@config_path)
        entry = data["heartbeats"]["full_beat"]
        assert_equal "Full description", entry["description"]
        assert_equal "/tmp/work", entry["working_dir"]
        assert_equal "auto", entry["permission_mode"]
        assert_equal true, entry["persistent"]
        assert_equal 120, entry["timeout"]
        assert_equal false, entry["enabled"]
      end

      test "create defaults enabled to true" do
        @handler.call("manage_heartbeat", {
                        "action" => "create", "name" => "beat", "cron" => "0 0 * * *", "prompt" => "Test"
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal true, data["heartbeats"]["beat"]["enabled"]
      end

      # --- update ---

      test "update succeeds with partial fields" do
        write_heartbeats(
          "existing" => {
            "description" => "Old description",
            "schedule" => { "cron" => "0 0 * * *" },
            "channel_id" => "ch-123",
            "prompt" => "Old prompt",
            "enabled" => true
          }
        )

        result = @handler.call("manage_heartbeat", {
                                 "action" => "update", "name" => "existing", "prompt" => "New prompt"
                               })

        text = result[:content].first[:text]
        assert_includes text, "Updated heartbeat 'existing'"

        data = YAML.safe_load_file(@config_path)
        entry = data["heartbeats"]["existing"]
        assert_equal "New prompt", entry["prompt"]
        assert_equal "Old description", entry["description"] # unchanged
        assert_equal "0 0 * * *", entry["schedule"]["cron"] # unchanged
      end

      test "update returns error when name is missing" do
        result = @handler.call("manage_heartbeat", { "action" => "update", "prompt" => "New" })
        text = result[:content].first[:text]
        assert_includes text, "Error: name is required"
      end

      test "update returns error for nonexistent heartbeat" do
        result = @handler.call("manage_heartbeat", {
                                 "action" => "update", "name" => "ghost", "prompt" => "New"
                               })
        text = result[:content].first[:text]
        assert_includes text, "not found"
      end

      test "update can change cron schedule" do
        write_heartbeats(
          "beat" => {
            "schedule" => { "cron" => "0 0 * * *" },
            "channel_id" => "ch", "prompt" => "p"
          }
        )

        @handler.call("manage_heartbeat", {
                        "action" => "update", "name" => "beat", "cron" => "0 9 * * 1-5"
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal "0 9 * * 1-5", data["heartbeats"]["beat"]["schedule"]["cron"]
      end

      test "update can change interval schedule" do
        write_heartbeats(
          "beat" => {
            "schedule" => { "interval" => 3600 },
            "channel_id" => "ch", "prompt" => "p"
          }
        )

        @handler.call("manage_heartbeat", {
                        "action" => "update", "name" => "beat", "interval" => 7200
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal 7200, data["heartbeats"]["beat"]["schedule"]["interval"]
      end

      test "update can disable a heartbeat" do
        write_heartbeats(
          "beat" => {
            "schedule" => { "cron" => "0 0 * * *" },
            "channel_id" => "ch", "prompt" => "p", "enabled" => true
          }
        )

        @handler.call("manage_heartbeat", {
                        "action" => "update", "name" => "beat", "enabled" => false
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal false, data["heartbeats"]["beat"]["enabled"]
      end

      # --- delete ---

      test "delete succeeds for existing heartbeat" do
        write_heartbeats(
          "doomed" => {
            "schedule" => { "cron" => "0 0 * * *" },
            "channel_id" => "ch", "prompt" => "p"
          }
        )

        result = @handler.call("manage_heartbeat", {
                                 "action" => "delete", "name" => "doomed"
                               })

        text = result[:content].first[:text]
        assert_includes text, "Deleted heartbeat 'doomed'"

        data = YAML.safe_load_file(@config_path)
        assert_not data["heartbeats"].key?("doomed")
      end

      test "delete returns error when name is missing" do
        result = @handler.call("manage_heartbeat", { "action" => "delete" })
        text = result[:content].first[:text]
        assert_includes text, "Error: name is required"
      end

      test "delete returns error for nonexistent heartbeat" do
        result = @handler.call("manage_heartbeat", {
                                 "action" => "delete", "name" => "ghost"
                               })
        text = result[:content].first[:text]
        assert_includes text, "not found"
      end

      test "delete preserves other heartbeats" do
        write_heartbeats(
          "keep_me" => { "schedule" => { "cron" => "0 0 * * *" }, "channel_id" => "ch", "prompt" => "p" },
          "delete_me" => { "schedule" => { "cron" => "0 0 * * *" }, "channel_id" => "ch", "prompt" => "p" }
        )

        @handler.call("manage_heartbeat", { "action" => "delete", "name" => "delete_me" })

        data = YAML.safe_load_file(@config_path)
        assert data["heartbeats"].key?("keep_me")
        assert_not data["heartbeats"].key?("delete_me")
      end

      # --- round-trip with HeartbeatConfig ---

      test "created YAML is loadable by HeartbeatConfig" do
        @handler.call("manage_heartbeat", {
                        "action" => "create",
                        "name" => "roundtrip_test",
                        "cron" => "0 9 * * 1-5",
                        "prompt" => "Test round-trip",
                        "channel_id" => "ch-999",
                        "description" => "Round-trip test"
                      })

        config = Earl::HeartbeatConfig.new(path: @config_path)
        defs = config.definitions
        assert_equal 1, defs.size
        assert_equal "roundtrip_test", defs.first.name
        assert_equal "0 9 * * 1-5", defs.first.cron
        assert_equal "Test round-trip", defs.first.prompt
        assert_equal "ch-999", defs.first.channel_id
      end

      # --- once flag ---

      test "create with once true stores in YAML" do
        @handler.call("manage_heartbeat", {
                        "action" => "create",
                        "name" => "once_beat",
                        "once" => true,
                        "run_at" => 1_739_559_600,
                        "prompt" => "One-off task",
                        "channel_id" => "ch-123"
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal true, data["heartbeats"]["once_beat"]["once"]
        assert_equal 1_739_559_600, data["heartbeats"]["once_beat"]["schedule"]["run_at"]
      end

      test "create with once true and no schedule auto-sets run_at" do
        @handler.call("manage_heartbeat", {
                        "action" => "create",
                        "name" => "immediate_beat",
                        "once" => true,
                        "prompt" => "Do it now"
                      })

        data = YAML.safe_load_file(@config_path)
        entry = data["heartbeats"]["immediate_beat"]
        assert_equal true, entry["once"]
        assert entry["schedule"].key?("run_at"), "Expected schedule to have run_at auto-set"
        assert_kind_of Integer, entry["schedule"]["run_at"]
        # run_at should be approximately now (within 5 seconds)
        assert_in_delta Time.now.to_i, entry["schedule"]["run_at"], 5
      end

      test "create with run_at stores in schedule" do
        @handler.call("manage_heartbeat", {
                        "action" => "create",
                        "name" => "scheduled_beat",
                        "run_at" => 1_739_559_600,
                        "prompt" => "Scheduled task"
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal 1_739_559_600, data["heartbeats"]["scheduled_beat"]["schedule"]["run_at"]
      end

      test "create with once true and explicit cron does not auto-set run_at" do
        @handler.call("manage_heartbeat", {
                        "action" => "create",
                        "name" => "once_cron_beat",
                        "once" => true,
                        "cron" => "0 9 * * 1-5",
                        "prompt" => "Once with cron"
                      })

        data = YAML.safe_load_file(@config_path)
        entry = data["heartbeats"]["once_cron_beat"]
        assert_equal true, entry["once"]
        assert_equal "0 9 * * 1-5", entry["schedule"]["cron"]
        assert_not entry["schedule"].key?("run_at"), "run_at should not be auto-set when cron is provided"
      end

      test "list shows once badge and run_at schedule" do
        write_heartbeats(
          "reminder" => {
            "description" => "Deploy reminder",
            "schedule" => { "run_at" => 1_739_559_600 },
            "channel_id" => "ch-123",
            "prompt" => "Check deploy",
            "once" => true,
            "enabled" => true
          }
        )

        result = @handler.call("manage_heartbeat", { "action" => "list" })
        text = result[:content].first[:text]
        assert_includes text, "once"
        assert_includes text, "run_at:"
        assert_includes text, "reminder"
      end

      test "round-trip once plus run_at loadable by HeartbeatConfig" do
        @handler.call("manage_heartbeat", {
                        "action" => "create",
                        "name" => "once_roundtrip",
                        "once" => true,
                        "run_at" => 1_739_559_600,
                        "prompt" => "One-shot task",
                        "channel_id" => "ch-999"
                      })

        config = Earl::HeartbeatConfig.new(path: @config_path)
        defs = config.definitions
        assert_equal 1, defs.size
        assert_equal "once_roundtrip", defs.first.name
        assert_equal true, defs.first.once
        assert_equal 1_739_559_600, defs.first.run_at
      end

      test "update can set run_at on existing heartbeat" do
        write_heartbeats(
          "beat" => {
            "schedule" => { "cron" => "0 0 * * *" },
            "channel_id" => "ch", "prompt" => "p"
          }
        )

        @handler.call("manage_heartbeat", {
                        "action" => "update", "name" => "beat", "run_at" => 1_739_559_600
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal 1_739_559_600, data["heartbeats"]["beat"]["schedule"]["run_at"]
      end

      test "update can set once on existing heartbeat" do
        write_heartbeats(
          "beat" => {
            "schedule" => { "run_at" => 1_739_559_600 },
            "channel_id" => "ch", "prompt" => "p"
          }
        )

        @handler.call("manage_heartbeat", {
                        "action" => "update", "name" => "beat", "once" => true
                      })

        data = YAML.safe_load_file(@config_path)
        assert_equal true, data["heartbeats"]["beat"]["once"]
      end

      private

      test "load_yaml returns default when YAML is not a Hash" do
        File.write(@config_path, YAML.dump("just a string"))

        result = @handler.call("manage_heartbeat", { "action" => "list" })
        assert_includes result[:content].first[:text], "No heartbeats"
      end

      test "list shows no schedule for heartbeat without cron interval or run_at" do
        write_heartbeats(
          "orphan" => {
            "schedule" => {},
            "channel_id" => "ch",
            "prompt" => "p",
            "enabled" => true
          }
        )

        result = @handler.call("manage_heartbeat", { "action" => "list" })
        assert_includes result[:content].first[:text], "no schedule"
      end

      def write_heartbeats(heartbeats)
        File.write(@config_path, YAML.dump("heartbeats" => heartbeats))
      end
    end
  end
end
