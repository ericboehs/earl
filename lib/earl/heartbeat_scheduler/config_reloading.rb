# frozen_string_literal: true

module Earl
  class HeartbeatScheduler
    # Auto-reload: detects config file changes and updates heartbeat definitions.
    module ConfigReloading
      private

      def check_for_reload
        mtime = config_file_mtime
        return if mtime == @control.config_mtime

        @control.config_mtime = mtime
        reload_definitions
      end

      def reload_definitions
        new_defs = @deps.heartbeat_config.definitions
        now = Time.now
        new_names = new_defs.map(&:name)

        @mutex.synchronize do
          add_new_definitions(new_defs, now)
          remove_stale_definitions(new_names)
          update_existing_definitions(new_defs)
        end

        log(:info, "Heartbeat config reloaded: #{new_defs.size} definition(s)")
      end

      def add_new_definitions(new_defs, now)
        new_defs.each do |definition|
          def_name = definition.name
          next if @states.key?(def_name)

          @states[def_name] = build_initial_state(definition, now)
          log(:info, "Heartbeat reload: added '#{def_name}'")
        end
      end

      def remove_stale_definitions(new_names)
        @states.each_key do |name|
          next if new_names.include?(name)
          next if @states[name].running

          @states.delete(name)
          log(:info, "Heartbeat reload: removed '#{name}'")
        end
      end

      def update_existing_definitions(new_defs)
        new_defs.each do |definition|
          @states[definition.name]&.update_definition_if_idle(definition)
        end
      end

      def config_file_mtime
        File.mtime(@control.heartbeat_config_path)
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
