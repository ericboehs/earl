# frozen_string_literal: true

module Earl
  # Manages a PID file to prevent duplicate EARL instances per environment.
  # Each environment (prod/dev) gets its own PID file under its config_root.
  module PidFile
    module_function

    def path
      File.join(Earl.config_root, "earl.pid")
    end

    def check!
      existing_pid = read_pid
      return unless existing_pid

      verify_not_running!(existing_pid)
    end

    def read_pid
      return nil unless File.exist?(path)

      pid = File.read(path).strip.to_i
      pid.positive? && pid != Process.pid ? pid : nil
    end

    def verify_not_running!(existing_pid)
      Process.kill(0, existing_pid)
      abort "EARL is already running (pid #{existing_pid}). Aborting."
    rescue Errno::ESRCH
      FileUtils.rm_f(path)
      Earl.logger.warn "Removed stale PID file (pid #{existing_pid} not found)"
    rescue Errno::EPERM
      abort "EARL is already running (pid #{existing_pid}, owned by another user). Aborting."
    end

    def write!
      File.write(path, Process.pid.to_s)
    end

    def cleanup!
      FileUtils.rm_f(path)
    end
  end
end
