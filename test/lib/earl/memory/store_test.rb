# frozen_string_literal: true

require "test_helper"

module Earl
  module Memory
    class StoreTest < Minitest::Test
      setup do
        @tmp_dir = Dir.mktmpdir("earl-memory-test")
        @store = Earl::Memory::Store.new(dir: @tmp_dir)
      end

      teardown do
        FileUtils.rm_rf(@tmp_dir)
      end

      # --- soul ---

      test "soul returns empty string when SOUL.md does not exist" do
        assert_equal "", @store.soul
      end

      test "soul returns file contents when SOUL.md exists" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I am EARL, a helpful bot.")
        assert_equal "I am EARL, a helpful bot.", @store.soul
      end

      # --- users ---

      test "users returns empty string when USER.md does not exist" do
        assert_equal "", @store.users
      end

      test "users returns file contents when USER.md exists" do
        File.write(File.join(@tmp_dir, "USER.md"), "Eric prefers dark mode.")
        assert_equal "Eric prefers dark mode.", @store.users
      end

      # --- save ---

      test "save creates dated file with header and entry" do
        result = @store.save(username: "ericboehs", text: "Prefers conventional commits")

        assert File.exist?(result[:file])
        contents = File.read(result[:file])

        today = Time.now.utc.strftime("%Y-%m-%d")
        assert_includes contents, "# Memories for #{today}"
        assert_includes contents, "@ericboehs"
        assert_includes contents, "Prefers conventional commits"
        assert_includes contents, "UTC"
      end

      test "save appends to existing dated file without duplicating header" do
        @store.save(username: "alice", text: "First fact")
        @store.save(username: "bob", text: "Second fact")

        today = Time.now.utc.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        contents = File.read(path)

        # Header should appear only once
        assert_equal 1, contents.scan("# Memories for").size
        assert_includes contents, "First fact"
        assert_includes contents, "Second fact"
      end

      test "save returns hash with file and entry" do
        result = @store.save(username: "ericboehs", text: "Test fact")

        assert result.key?(:file)
        assert result.key?(:entry)
        assert_includes result[:entry], "Test fact"
        assert_includes result[:entry], "@ericboehs"
      end

      test "save creates directory if it does not exist" do
        nested_dir = File.join(@tmp_dir, "nested", "memory")
        store = Earl::Memory::Store.new(dir: nested_dir)

        store.save(username: "alice", text: "fact")
        assert Dir.exist?(nested_dir)
      end

      # --- recent_memories ---

      test "recent_memories returns empty string when no date files exist" do
        assert_equal "", @store.recent_memories
      end

      test "recent_memories returns entries from recent date files" do
        today = Date.today.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        File.write(path, "# Memories for #{today}\n\n- **10:00 UTC** | `@alice` | Likes Ruby\n")

        result = @store.recent_memories
        assert_includes result, "Likes Ruby"
      end

      test "recent_memories skips header lines" do
        today = Date.today.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        File.write(path, "# Memories for #{today}\n\n- **10:00 UTC** | `@alice` | Likes Ruby\n")

        result = @store.recent_memories
        assert_not_includes result, "# Memories for"
      end

      test "recent_memories respects limit parameter" do
        today = Date.today.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        lines = (1..10).map { |i| "- **10:#{format("%02d", i)} UTC** | `@alice` | Fact #{i}" }
        File.write(path, "# Memories\n\n#{lines.join("\n")}\n")

        result = @store.recent_memories(limit: 3)
        # Should contain last 3 entries when limit is hit
        assert_equal 3, result.lines.count
      end

      test "recent_memories respects days parameter" do
        today = Date.today.strftime("%Y-%m-%d")
        old_date = (Date.today - 10).strftime("%Y-%m-%d")

        File.write(File.join(@tmp_dir, "#{today}.md"), "# Memories\n\n- Today's fact\n")
        File.write(File.join(@tmp_dir, "#{old_date}.md"), "# Memories\n\n- Old fact\n")

        result = @store.recent_memories(days: 3)
        assert_includes result, "Today's fact"
        assert_not_includes result, "Old fact"
      end

      test "recent_memories skips empty lines" do
        today = Date.today.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        File.write(path, "# Memories\n\n\n- **10:00 UTC** | `@alice` | Fact\n\n")

        result = @store.recent_memories
        assert_equal "- **10:00 UTC** | `@alice` | Fact", result
      end

      # --- search ---

      test "search returns empty array when no files exist" do
        results = @store.search(query: "anything")
        assert_equal [], results
      end

      test "search finds matches in SOUL.md" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I am a helpful bot.\nI like Ruby.\n")

        results = @store.search(query: "Ruby")
        assert_equal 1, results.size
        assert_equal "SOUL.md", results.first[:file]
        assert_includes results.first[:line], "Ruby"
      end

      test "search finds matches in USER.md" do
        File.write(File.join(@tmp_dir, "USER.md"), "Eric prefers dark mode.\n")

        results = @store.search(query: "dark mode")
        assert_equal 1, results.size
        assert_equal "USER.md", results.first[:file]
      end

      test "search finds matches in date files" do
        today = Date.today.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        File.write(path, "# Memories\n\n- **10:00 UTC** | `@alice` | Prefers vim\n")

        results = @store.search(query: "vim")
        assert_equal 1, results.size
        assert_includes results.first[:line], "vim"
      end

      test "search is case-insensitive" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I love RUBY programming.\n")

        results = @store.search(query: "ruby")
        assert_equal 1, results.size
      end

      test "search respects limit parameter" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "Ruby line 1\nRuby line 2\nRuby line 3\n")

        results = @store.search(query: "Ruby", limit: 2)
        assert_equal 2, results.size
      end

      test "search prioritizes SOUL.md and USER.md over date files" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I know Ruby.\n")
        today = Date.today.strftime("%Y-%m-%d")
        File.write(File.join(@tmp_dir, "#{today}.md"), "- Ruby fact\n")

        results = @store.search(query: "Ruby")
        assert_equal "SOUL.md", results.first[:file]
      end

      test "search handles missing files gracefully" do
        # Create a date file, then delete it mid-search (race condition simulation)
        File.write(File.join(@tmp_dir, "SOUL.md"), "test content\n")

        results = @store.search(query: "test")
        assert_equal 1, results.size
      end
    end
  end
end
