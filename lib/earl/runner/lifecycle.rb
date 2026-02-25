# frozen_string_literal: true

require "rbconfig"

module Earl
  class Runner
    # Shutdown, restart, and process lifecycle management.
    module Lifecycle
      private

      def begin_shutdown(&)
        return if @app_state.shutting_down

        @app_state.shutting_down = true
        @app_state.shutdown_thread = Thread.new(&)
      end

      def handle_shutdown_signal
        begin_shutdown { shutdown }
      end

      def handle_restart_signal
        @app_state.pending_restart = true
        begin_shutdown { restart }
      end

      def shutdown
        log(:info, "Shutting down...")
        @app_state.idle_checker_thread&.kill
        @services.heartbeat_scheduler.stop
        @services.tmux_monitor.stop
        @services.session_manager.pause_all
        log(:info, "Goodbye!")
      end

      def restart
        updating = @app_state.pending_update
        log(:info, updating ? "Updating EARL..." : "Restarting EARL...")
        pull_latest if updating || !Earl.development?
        update_dependencies if updating
        shutdown
      end

      def wait_and_exec_restart
        @app_state.shutdown_thread&.join
        cmd = [RbConfig.ruby, $PROGRAM_NAME]
        log(:info, "Exec: #{cmd.join(" ")}")
        Bundler.with_unbundled_env { Kernel.exec(*cmd) }
      end

      def pull_latest
        run_in_repo("git pull --ff-only", "git", "pull", "--ff-only")
      end

      def update_dependencies
        run_in_repo("bundle install", { "RUBYOPT" => "-W0" }, "bundle", "install", "--quiet")
      end

      def run_in_repo(label, *cmd)
        Dir.chdir(File.dirname($PROGRAM_NAME)) do
          result = system(*cmd) ? "succeeded" : "failed (continuing)"
          log(result.start_with?("s") ? :info : :warn, "#{label} #{result}")
        end
      rescue StandardError => error
        log(:warn, "#{label} failed: #{error.message}")
      end
    end
  end
end
