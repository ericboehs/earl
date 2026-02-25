# frozen_string_literal: true

module Earl
  class Runner
    # Startup, channel configuration, and restart notification logic.
    module Startup
      private

      def configure_channels
        channels = @services.config.channels
        @services.mattermost.configure_channels(Set.new(channels.keys)) if channels.size > 1
      end

      def log_startup
        config = @services.config
        channel_names = resolve_channel_names(config.channels.keys)
        count = channel_names.size
        log(:info,
            "EARL is running. Listening in #{count} channel#{"s" unless count == 1}: #{channel_names.join(", ")}")
        log(:info, "Allowed users: #{config.allowed_users.join(", ")}")
        notify_restart
      end

      def notify_restart
        data = read_restart_context
        return unless data

        verb = data["command"] == "update" ? "updated" : "restarted"
        @services.mattermost.create_post(
          channel_id: data["channel_id"],
          message: ":white_check_mark: EARL #{verb} successfully.",
          root_id: data["thread_id"]
        )
      rescue StandardError => error
        log(:warn, "Failed to post restart notification: #{error.message}")
      end

      def read_restart_context
        path = File.join(Earl.config_root, "restart_context.json")
        data = JSON.parse(File.read(path))
        File.delete(path)
        data
      rescue Errno::ENOENT
        nil
      end

      def resolve_channel_names(channel_ids)
        channel_ids.map do |id|
          info = @services.mattermost.get_channel(channel_id: id)
          info&.fetch("display_name", nil) || info&.fetch("name", nil) || id[0..7]
        end
      end

      def start_background_services
        start_idle_checker
        @services.heartbeat_scheduler.start
        @services.tmux_monitor.start
      end

      def setup_handlers
        setup_signal_handlers
        setup_message_handler
        setup_reaction_handler
      end

      def setup_signal_handlers
        %w[INT TERM].each { |signal| trap(signal) { handle_shutdown_signal } }
        trap("HUP") { handle_restart_signal }
      end
    end
  end
end
