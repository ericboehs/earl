# frozen_string_literal: true

module Earl
  module Tmux
    # Private parsing helpers for tmux output formats.
    # Extracted to keep the main Tmux module under the line limit.
    module Parsing
      private

      def build_format(fields)
        fields.map { |field| "\#{#{field}}" }.join(FIELD_SEP)
      end

      def parse_session_line(line)
        parts = line.strip.split(FIELD_SEP, 3)
        return if parts.size < 3

        { name: parts[0], attached: parts[1] != "0",
          created_at: Time.at(parts[2].to_i).strftime("%c") }
      end

      def no_server_or_sessions?(error)
        msg = error.message
        msg.include?("no server running") || msg.include?("no sessions")
      end

      def parse_pane_lines(output, field_count)
        output.each_line.filter_map do |line|
          parts = line.strip.split(FIELD_SEP, field_count)
          next if parts.size < field_count

          { index: parts[0].to_i, command: parts[1], path: parts[2], pid: parts[3].to_i }
        end
      end

      def parse_all_pane_line(line, field_count)
        parts = line.strip.split(FIELD_SEP, field_count)
        return if parts.size < field_count

        build_all_pane_hash(parts)
      end

      def build_all_pane_hash(parts)
        session, window, pane_idx, command, path, pid, tty = parts
        { target: "#{session}:#{window}.#{pane_idx}", session: session,
          window: window.to_i, pane_index: pane_idx.to_i,
          command: command, path: path, pid: pid.to_i, tty: tty }
      end

      def build_create_window_args(options)
        session = options.fetch(:session)
        name = options[:name]
        working_dir = options[:working_dir]
        command = options[:command]
        args = ["tmux", "new-window", "-t", session]
        args.push("-n", name) if name
        args.push("-c", working_dir) if working_dir
        args.push(command) if command
        args
      end

      def fetch_parent_command(pid_str)
        output, _status = Open3.capture2e("ps", "-o", "comm=", "-p", pid_str)
        output.strip
      end

      def fetch_child_commands
        output, = Open3.capture2e("ps", "-eo", "pid=,ppid=,comm=")
        parse_process_entries(output)
      end

      def parse_process_entries(output)
        output.each_line.filter_map do |line|
          parts = line.strip.split(/\s+/, 3)
          { ppid: parts[1], comm: parts[2] } if parts.size >= 3
        end
      end
    end
  end
end
