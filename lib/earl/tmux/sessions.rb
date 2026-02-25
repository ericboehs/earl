# frozen_string_literal: true

module Earl
  module Tmux
    # Session lifecycle: create, kill, check existence.
    module Sessions
      def create_session(name:, command: nil, working_dir: nil)
        cmd = build_session_args(name, command, working_dir)
        execute(*cmd)
      end

      def create_window(**options)
        build_create_window_args(options).then { |args| execute(*args) }
      end

      def kill_session(name)
        execute("tmux", "kill-session", "-t", name)
      rescue Error => error
        raise NotFound, "Session '#{name}' not found" if error.message.include?("can't find")

        raise
      end

      def session_exists?(name)
        execute("tmux", "has-session", "-t", name)
        true
      rescue Error
        false
      end

      private

      def build_session_args(name, command, working_dir)
        args = ["tmux", "new-session", "-d", "-s", name]
        args.push("-c", working_dir) if working_dir
        args.push(command) if command
        args
      end
    end
  end
end
