# frozen_string_literal: true

module Earl
  class CommandExecutor
    # Handles the !spawn command — creates a new Claude session in tmux.
    module SpawnHandler
      # Bundles spawn parameters extracted from the command.
      SpawnRequest = Struct.new(:name, :prompt, :working_dir, keyword_init: true) do
        def to_session_info(ctx)
          TmuxSessionStore::TmuxSessionInfo.new(
            name: name, channel_id: ctx.channel_id, thread_id: ctx.thread_id,
            working_dir: working_dir, prompt: prompt, created_at: Time.now.iso8601
          )
        end
      end

      private

      def handle_spawn(ctx)
        prompt = ctx.arg
        if prompt.to_s.strip.empty?
          return reply(ctx, ':x: Usage: `!spawn "prompt" [--name N] [--dir D]`')
        end

        req = build_spawn_request(prompt, ctx.args[1].to_s)
        validate_and_spawn(ctx, req)
      rescue Tmux::Error => error
        reply(ctx, ":x: Failed to spawn session: #{error.message}")
      end

      def build_spawn_request(prompt, flags_str)
        parsed = parse_spawn_flags(flags_str)
        name = parsed[:name] || generate_session_name
        SpawnRequest.new(name: name, prompt: prompt, working_dir: parsed[:dir])
      end

      def generate_session_name
        "earl-#{Time.now.strftime('%Y%m%d%H%M%S')}"
      end

      def validate_and_spawn(ctx, req)
        name = req.name
        return if spawn_name_invalid?(ctx, name)
        return if spawn_dir_invalid?(ctx, req.working_dir)
        return if spawn_name_taken?(ctx, name)

        spawn_tmux_session(ctx, req)
      end

      def spawn_name_invalid?(ctx, name)
        return false unless name.match?(/[.:]/)

        reply(ctx, ":x: Invalid session name `#{name}`: cannot contain `.` or `:` (tmux reserved).")
        true
      end

      def spawn_dir_invalid?(ctx, working_dir)
        return false unless working_dir
        return false if Dir.exist?(working_dir)

        reply(ctx, ":x: Directory not found: `#{working_dir}`")
        true
      end

      def spawn_name_taken?(ctx, name)
        return false unless @tmux.session_exists?(name)

        reply(ctx, ":x: Session `#{name}` already exists.")
        true
      end

      def spawn_tmux_session(ctx, req)
        name = req.name
        command = "claude #{Shellwords.shellescape(req.prompt)}"
        @tmux.create_session(name: name, command: command, working_dir: req.working_dir)
        save_tmux_session_info(ctx, req)
        reply(ctx, spawn_success_message(req))
      end

      def spawn_success_message(req)
        name = req.name
        ":rocket: Spawned tmux session `#{name}`\n" \
          "- **Prompt:** #{req.prompt}\n" \
          "- **Dir:** #{req.working_dir || Dir.pwd}\n" \
          "Use `!session #{name}` to check output."
      end

      def save_tmux_session_info(ctx, req)
        return unless @tmux_store

        @tmux_store.save(req.to_session_info(ctx))
      end

      def parse_spawn_flags(str)
        {
          dir: str[/--dir\s+(\S+)/, 1],
          name: str[/--name\s+(\S+)/, 1]
        }.compact
      end
    end
  end
end
