# frozen_string_literal: true

module Earl
  module Memory
    # Pure Ruby file I/O for reading, writing, and searching memory files.
    # Manages markdown-based persistent memory in ~/.config/earl/memory/
    # with SOUL.md (personality), USER.md (user notes), and YYYY-MM-DD.md (daily episodic).
    class Store
      def self.default_dir
        @default_dir ||= File.join(Earl.config_root, "memory")
      end

      def initialize(dir: self.class.default_dir)
        @dir = dir
      end

      def soul
        read_file("SOUL.md")
      end

      def users
        read_file("USER.md")
      end

      def recent_memories(days: 7, limit: 50)
        entries = collect_entries(days)
        entries.last(limit).join("\n")
      rescue Errno::ENOENT
        ""
      end

      def save(username:, text:)
        FileUtils.mkdir_p(@dir)
        now = Time.now.utc
        today = now.strftime("%Y-%m-%d")
        path = File.join(@dir, "#{today}.md")
        entry = "- **#{now.strftime('%H:%M UTC')}** | `@#{username}` | #{text}"

        write_with_header(path, today, entry)
        { file: path, entry: entry }
      end

      def search(query:, limit: 20)
        pattern = Regexp.new(Regexp.escape(query), Regexp::IGNORECASE)
        grep_files(pattern, limit)
      end

      private

      def collect_entries(days)
        paths = date_files_descending(days)
        paths.flat_map { |path| entries_from_file(path) }
      end

      def entries_from_file(path)
        File.readlines(path).filter_map do |line|
          stripped = line.strip
          stripped unless stripped.empty? || stripped.start_with?("#")
        end
      end

      def grep_files(pattern, limit)
        search_files.each_with_object([]) do |path, matches|
          file_matches = matches_in_file(path, pattern)
          matches.concat(file_matches)
          break matches if matches.size >= limit
        rescue Errno::ENOENT
          next
        end.first(limit)
      end

      def matches_in_file(path, pattern)
        basename = File.basename(path)
        File.readlines(path).filter_map do |line|
          { file: basename, line: line.strip } if pattern.match?(line)
        end
      end

      def read_file(name)
        path = file_at(name)
        return "" unless path

        File.read(path)
      rescue Errno::ENOENT
        ""
      end

      def file_at(name)
        path = File.join(@dir, name)
        path if File.exist?(path)
      end

      def date_files_descending(days)
        today = Date.today
        (0...days).filter_map do |offset|
          file_at((today - offset).strftime("%Y-%m-%d.md"))
        end
      end

      def search_files
        priority = %w[SOUL.md USER.md].filter_map { |name| file_at(name) }
        date_files = Dir.glob(File.join(@dir, "????-??-??.md")).sort.reverse
        priority + date_files
      end

      def write_with_header(path, today, entry)
        File.open(path, "a") do |file|
          file.flock(File::LOCK_EX)
          if file.size.zero?
            file.puts "# Memories for #{today}"
            file.puts
          end
          file.puts entry
        end
      end
    end
  end
end
