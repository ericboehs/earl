# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Handles tmux session commands: !sessions, !session <name> show/status/
    # input/nudge/approve/deny/kill.
    module SessionHandler
      PANE_STATUS_LABELS = {
        active: "\u{1F7E2} Active",
        permission: "\u{1F7E0} Waiting for permission",
        idle: "\u{1F7E1} Idle"
      }.freeze

      private

      def handle_sessions(ctx)
        tmux = @deps.tmux
        return reply(ctx, ":x: tmux is not installed.") unless tmux.available?

        panes = tmux.list_all_panes
        return reply(ctx, "No tmux sessions running.") if panes.empty?

        claude_panes = panes.select { |pane| tmux.claude_on_tty?(pane[:tty]) }
        if claude_panes.empty?
          return reply(ctx, "No Claude sessions found across #{panes.size} tmux panes.")
        end

        reply(ctx, format_sessions_table(claude_panes))
      end

      def format_sessions_table(claude_panes)
        rows = claude_panes.map { |pane| format_claude_pane_row(pane) }
        build_sessions_output(rows)
      end

      def build_sessions_output(rows)
        header = [
          "#### :computer: Claude Sessions (#{rows.size})",
          "| Pane | Project | Status |",
          "|------|---------|--------|"
        ]
        (header + rows).join("\n")
      end

      def format_claude_pane_row(pane)
        target, path = pane.values_at(:target, :path)
        project = File.basename(path)
        status = detect_pane_status(target)
        label = PANE_STATUS_LABELS.fetch(status, "\u{1F7E1} Idle")
        "| `#{target}` | #{project} | #{label} |"
      end

      def detect_pane_status(target)
        output = @deps.tmux.capture_pane(target, lines: 20)
        return :permission if output.include?("Do you want to proceed?")
        return :active if output.include?("esc to interrupt")

        :idle
      rescue Tmux::Error => error
        log(:debug, "detect_pane_status failed for #{target}: #{error.message}")
        :idle
      end

      def handle_session_show(ctx)
        name = ctx.arg
        with_tmux_session(ctx) do
          output = @deps.tmux.capture_pane(name)
          truncated = truncate_output(output)
          reply(ctx, "#### :computer: `#{name}` pane output\n```\n#{truncated}\n```")
        end
      end

      def handle_session_status(ctx)
        name = ctx.arg
        with_tmux_session(ctx) do
          output = @deps.tmux.capture_pane(name, lines: 200)
          truncated = truncate_output(output, 3000)
          reply(ctx, "#### :mag: `#{name}` status\n```\n#{truncated}\n```\n_AI summary not yet implemented._")
        end
      end

      def handle_session_input(ctx)
        name = ctx.arg
        text = ctx.args[1]
        with_tmux_session(ctx) do
          @deps.tmux.send_keys(name, text)
          reply(ctx, ":keyboard: Sent to `#{name}`: `#{text}`")
        end
      end

      def handle_session_nudge(ctx)
        name = ctx.arg
        with_tmux_session(ctx) do
          @deps.tmux.send_keys(name, "Are you stuck? What's your current status?")
          reply(ctx, ":wave: Nudged `#{name}`.")
        end
      end

      def handle_session_approve(ctx)
        name = ctx.arg
        with_tmux_session(ctx) do
          @deps.tmux.send_keys_raw(name, "Enter")
          reply(ctx, ":white_check_mark: Approved permission on `#{name}`.")
        end
      end

      def handle_session_deny(ctx)
        name = ctx.arg
        with_tmux_session(ctx) do
          @deps.tmux.send_keys_raw(name, "Escape")
          reply(ctx, ":no_entry_sign: Denied permission on `#{name}`.")
        end
      end

      def handle_session_kill(ctx)
        name = ctx.arg
        store = @deps.tmux_store
        @deps.tmux.kill_session(name)
        store&.delete(name)
        reply(ctx, ":skull: Tmux session `#{name}` killed.")
      rescue Tmux::NotFound
        store&.delete(name)
        reply(ctx, ":x: Session `#{name}` not found (cleaned up store).")
      rescue Tmux::Error => error
        reply(ctx, ":x: Error killing session: #{error.message}")
      end

      def with_tmux_session(ctx)
        yield
      rescue Tmux::NotFound
        reply(ctx, ":x: Session `#{ctx.arg}` not found.")
      rescue Tmux::Error => error
        reply(ctx, ":x: Error: #{error.message}")
      end

      def truncate_output(output, max_length = 3500)
        output.length > max_length ? "\u2026#{output[-max_length..]}" : output
      end
    end
  end
end
