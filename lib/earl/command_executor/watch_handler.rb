# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Handles !watch and !unwatch commands — registers/unregisters tmux panes
    # in TmuxSessionStore so TmuxMonitor picks them up for monitoring.
    module WatchHandler
      # Bundles validated watch parameters for registration.
      WatchRequest = Data.define(:target, :pane, :store) do
        def to_session_info(thread_id:, channel_id:)
          TmuxSessionStore::TmuxSessionInfo.new(
            name: target, channel_id: channel_id, thread_id: thread_id,
            working_dir: pane[:path], prompt: nil, created_at: Time.now.iso8601
          )
        end
      end

      private

      def handle_watch(ctx)
        target = ctx.arg
        return reply(ctx, ":x: Usage: `!watch <pane>` (e.g. `!watch code:1.0`)") if target.to_s.strip.empty?

        store = @deps.tmux_store
        return reply(ctx, ":x: Tmux session store not configured.") unless store

        validate_and_watch(ctx, target, store)
      end

      def handle_unwatch(ctx)
        target = ctx.arg
        return reply(ctx, ":x: Usage: `!unwatch <pane>`") if target.to_s.strip.empty?

        store = @deps.tmux_store
        return reply(ctx, ":x: Tmux session store not configured.") unless store

        existing = store.get(target)
        return reply(ctx, ":x: `#{target}` is not being watched.") unless existing

        store.delete(target)
        reply(ctx, ":eyes: Stopped watching `#{target}`.")
      end

      def validate_and_watch(ctx, target, store)
        return reply(ctx, watch_already_message(target)) if store.get(target)

        pane = find_pane(target)
        return reply(ctx, ":x: Tmux target `#{target}` not found.") unless pane
        return reply(ctx, ":x: No Claude session detected on `#{target}`.") unless @deps.tmux.claude_on_tty?(pane[:tty])

        register_watch(ctx, WatchRequest.new(target: target, pane: pane, store: store))
      end

      def register_watch(ctx, req)
        target, store = req.deconstruct_keys(%i[target store]).values_at(:target, :store)
        reply(ctx, watch_success_message(target))
        store.save(req.to_session_info(thread_id: ctx.thread_id, channel_id: ctx.channel_id))
      end

      def find_pane(target)
        @deps.tmux.list_all_panes.find { |pane| pane[:target] == target }
      end

      def watch_success_message(target)
        ":eyes: Now watching `#{target}`. TmuxMonitor will post alerts in this thread."
      end

      def watch_already_message(target)
        ":information_source: `#{target}` is already being watched."
      end
    end
  end
end
