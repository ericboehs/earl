# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Handles session lifecycle commands: !stop, !escape, !kill, !cd.
    module LifecycleHandler
      private

      def handle_stop(ctx)
        @deps.session_manager.stop_session(ctx.thread_id)
        reply(ctx, ":stop_sign: Session stopped.")
      end

      def handle_escape(ctx)
        session = @deps.session_manager.get(ctx.thread_id)
        if session&.process_pid
          Process.kill("INT", session.process_pid)
          reply(ctx, ":warning: Sent SIGINT to Claude.")
        else
          reply(ctx, "No active session to interrupt.")
        end
      rescue Errno::ESRCH
        reply(ctx, "Process already exited.")
      end

      def handle_kill(ctx)
        session = @deps.session_manager.get(ctx.thread_id)
        if session&.process_pid
          Process.kill("KILL", session.process_pid)
          cleanup_and_reply(ctx, ":skull: Session force killed.")
        else
          reply(ctx, "No active session to kill.")
        end
      rescue Errno::ESRCH
        cleanup_and_reply(ctx, "Process already exited, session cleaned up.")
      end

      def handle_cd(ctx)
        cleaned = ctx.arg.to_s.strip
        return reply(ctx, ":x: Usage: `!cd <path>`") if cleaned.empty?

        expanded = File.expand_path(cleaned)
        apply_working_dir(ctx, expanded)
      end

      def apply_working_dir(ctx, expanded)
        if Dir.exist?(expanded)
          @working_dirs[ctx.thread_id] = expanded
          reply(ctx, ":file_folder: Working directory set to `#{expanded}` (applies to next new session)")
        else
          reply(ctx, ":x: Directory not found: `#{expanded}`")
        end
      end

      def cleanup_and_reply(ctx, message)
        @deps.session_manager.stop_session(ctx.thread_id)
        reply(ctx, message)
      end
    end
  end
end
