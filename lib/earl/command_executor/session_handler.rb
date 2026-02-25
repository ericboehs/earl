# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Handles tmux session commands: !sessions, !session <name> show/status/
    # input/nudge/approve/deny/kill.
    module SessionHandler
      PANE_STATUS_LABELS = {
        active: "\u{1F7E2} Active", permission: "\u{1F7E0} Waiting for permission", idle: "\u{1F7E1} Idle"
      }.freeze

      private

      def handle_sessions(ctx)
        tmux = @deps.tmux
        return reply(ctx, ":x: tmux is not installed.") unless tmux.available?

        panes = tmux.list_all_panes
        return reply(ctx, "No tmux sessions running.") if panes.empty?

        claude_panes = panes.select { |pane| tmux.claude_on_tty?(pane[:tty]) }
        return reply(ctx, "No Claude sessions found across #{panes.size} tmux panes.") if claude_panes.empty?

        reply(ctx, format_sessions_table(claude_panes))
      end

      def format_sessions_table(claude_panes)
        rows = claude_panes.map { |pane| format_claude_pane_row(pane) }
        header = [
          "#### :computer: Claude Sessions (#{rows.size})",
          "| Pane | Project | Status |", "|------|---------|--------|"
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
        with_tmux_session(ctx) do
          target = ctx.arg
          output = @deps.tmux.capture_pane(target)
          reply(ctx, "#### :computer: `#{target}` pane output\n```\n#{truncate_output(output)}\n```")
        end
      end

      def handle_session_status(ctx)
        with_tmux_session(ctx) do
          target = ctx.arg
          output = @deps.tmux.capture_pane(target, lines: 200)
          truncated = truncate_output(output, 3000)
          reply(ctx, "#### :mag: `#{target}` status\n```\n#{truncated}\n```\n_AI summary not yet implemented._")
        end
      end

      def handle_session_input(ctx)
        with_tmux_session(ctx) do
          target = ctx.arg
          text = ctx.args[1]
          @deps.tmux.send_keys(target, text)
          reply(ctx, ":keyboard: Sent to `#{target}`: `#{text}`")
        end
      end

      def handle_session_nudge(ctx)
        with_tmux_session(ctx) do
          target = ctx.arg
          @deps.tmux.send_keys(target, "Are you stuck? What's your current status?")
          reply(ctx, ":wave: Nudged `#{target}`.")
        end
      end

      def handle_session_approve(ctx) = send_tmux_key_action(ctx, "Enter", ":white_check_mark: Approved permission on")
      def handle_session_deny(ctx) = send_tmux_key_action(ctx, "Escape", ":no_entry_sign: Denied permission on")

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

      def send_tmux_key_action(ctx, key, message_prefix)
        with_tmux_session(ctx) do
          target = ctx.arg
          @deps.tmux.send_keys_raw(target, key)
          reply(ctx, "#{message_prefix} `#{target}`.")
        end
      end
    end
  end
end
