# frozen_string_literal: true

module Earl
  class HeartbeatScheduler
    # Heartbeat lifecycle: finalization, next-run computation, and one-shot disabling.
    module Lifecycle
      private

      def finalize_heartbeat(state)
        definition = state.definition
        is_once = definition.once
        next_run = is_once ? nil : compute_next_run(definition, Time.now)
        @mutex.synchronize { state.mark_completed(next_run) }
        disable_heartbeat(definition.name) if is_once
      end

      def compute_next_run(definition, from)
        schedule = definition.to_h.values_at(:run_at, :cron, :interval)
        compute_from_schedule(schedule, from)
      end

      def compute_from_schedule(schedule, from)
        run_at, cron, interval = schedule
        if run_at
          compute_run_at(run_at, from)
        elsif cron
          CronParser.new(cron).next_occurrence(from: from)
        elsif interval
          from + interval
        end
      end

      def compute_run_at(run_at, from)
        target = Time.at(run_at)
        [target, from].max
      end

      def disable_heartbeat(name)
        path = @control.heartbeat_config_path
        return unless File.exist?(path)

        update_yaml_entry(path, name)
      rescue StandardError => error
        log(:warn, "Failed to disable heartbeat '#{name}': #{error.message}")
      end

      def update_yaml_entry(path, name)
        File.open(path, "r+") do |lockfile|
          lockfile.flock(File::LOCK_EX)
          yaml_data = YAML.safe_load_file(path)
          next unless disable_entry(yaml_data, name)

          write_yaml_atomically(path, yaml_data)
          log(:info, "One-off heartbeat '#{name}' disabled in YAML")
        end
      end

      def disable_entry(yaml_data, name)
        return false unless yaml_data.is_a?(Hash)

        entry = yaml_data.dig("heartbeats", name)
        return false unless entry.is_a?(Hash)

        entry["enabled"] = false
        true
      end

      def write_yaml_atomically(path, data)
        tmp_path = "#{path}.tmp.#{Process.pid}"
        File.write(tmp_path, YAML.dump(data))
        File.rename(tmp_path, path)
      end
    end
  end
end
