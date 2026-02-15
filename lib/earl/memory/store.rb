# frozen_string_literal: true

module Earl
  module Memory
    # Pure Ruby file I/O for reading, writing, and searching memory files.
    # Manages markdown-based persistent memory in ~/.config/earl/memory/
    # with SOUL.md (personality), USER.md (user notes), and YYYY-MM-DD.md (daily episodic).
    class Store
      DEFAULT_DIR = File.expand_path("~/.config/earl/memory")

      def initialize(dir: DEFAULT_DIR)
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
        entries = []
        date_files_descending(days).each do |path|
          File.readlines(path).each do |line|
            stripped = line.strip
            next if stripped.empty? || stripped.start_with?("#")

            entries << stripped
          end
        end
        entries
      end

      def grep_files(pattern, limit)
        results = []
        search_files.each do |path|
          File.readlines(path).each do |line|
            next unless pattern.match?(line)

            results << { file: File.basename(path), line: line.strip }
            return results if results.size >= limit
          end
        rescue Errno::ENOENT
          next
        end
        results
      end

      def read_file(name)
        path = File.join(@dir, name)
        return "" unless File.exist?(path)

        File.read(path)
      rescue Errno::ENOENT
        ""
      end

      def date_files_descending(days)
        today = Date.today
        (0...days).filter_map do |offset|
          date_str = (today - offset).strftime("%Y-%m-%d")
          path = File.join(@dir, "#{date_str}.md")
          path if File.exist?(path)
        end
      end

      def search_files
        priority = %w[SOUL.md USER.md].filter_map do |name|
          path = File.join(@dir, name)
          path if File.exist?(path)
        end

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
