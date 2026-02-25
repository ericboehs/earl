# frozen_string_literal: true

require "test_helper"

module Earl
  module Mcp
    class MemoryHandlerTest < Minitest::Test
      setup do
        @tmp_dir = Dir.mktmpdir("earl-memory-handler-test")
        @store = Earl::Memory::Store.new(dir: @tmp_dir)
        @handler = Earl::Mcp::MemoryHandler.new(store: @store, username: "testuser")
      end

      teardown do
        FileUtils.rm_rf(@tmp_dir)
      end

      # --- tool_definitions ---

      test "tool_definitions returns two tools" do
        defs = @handler.tool_definitions
        assert_equal 2, defs.size
        names = defs.map { |d| d[:name] }
        assert_includes names, "save_memory"
        assert_includes names, "search_memory"
      end

      test "tool_definitions include inputSchema" do
        defs = @handler.tool_definitions
        defs.each do |tool_def|
          assert tool_def.key?(:inputSchema), "#{tool_def[:name]} should have inputSchema"
          assert_equal "object", tool_def[:inputSchema][:type]
        end
      end

      # --- handles? ---

      test "handles? returns true for save_memory" do
        assert @handler.handles?("save_memory")
      end

      test "handles? returns true for search_memory" do
        assert @handler.handles?("search_memory")
      end

      test "handles? returns false for other tools" do
        assert_not @handler.handles?("permission_prompt")
        assert_not @handler.handles?("Bash")
      end

      # --- call save_memory ---

      test "call save_memory saves a fact and returns confirmation" do
        result = @handler.call("save_memory", { "text" => "Prefers dark mode" })

        assert result.key?(:content)
        text = result[:content].first[:text]
        assert_includes text, "Saved:"
        assert_includes text, "Prefers dark mode"
        assert_includes text, "@testuser"
      end

      test "call save_memory creates file on disk" do
        @handler.call("save_memory", { "text" => "Uses vim" })

        today = Time.now.utc.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        assert File.exist?(path)
        assert_includes File.read(path), "Uses vim"
      end

      test "call save_memory uses provided username" do
        @handler.call("save_memory", { "text" => "Likes Ruby", "username" => "alice" })

        today = Time.now.utc.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        assert_includes File.read(path), "@alice"
      end

      test "call save_memory falls back to handler username" do
        @handler.call("save_memory", { "text" => "Fact without username" })

        today = Time.now.utc.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        assert_includes File.read(path), "@testuser"
      end

      test "call save_memory handles missing text gracefully" do
        result = @handler.call("save_memory", {})
        assert result.key?(:content)
        assert_includes result[:content].first[:text], "Saved:"
      end

      test "call save_memory supports fact as alias for text" do
        result = @handler.call("save_memory", { "fact" => "Likes tests" })
        assert_includes result[:content].first[:text], "Likes tests"
      end

      # --- call search_memory ---

      test "call search_memory returns no results message when empty" do
        result = @handler.call("search_memory", { "query" => "nonexistent" })

        text = result[:content].first[:text]
        assert_includes text, "No memories found"
      end

      test "call search_memory finds matching memories" do
        @store.save(username: "alice", text: "Prefers Ruby on Rails")

        result = @handler.call("search_memory", { "query" => "Ruby" })

        text = result[:content].first[:text]
        assert_includes text, "Found"
        assert_includes text, "Ruby"
      end

      test "call search_memory respects limit" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "Ruby line 1\nRuby line 2\nRuby line 3\n")

        result = @handler.call("search_memory", { "query" => "Ruby", "limit" => 2 })

        text = result[:content].first[:text]
        assert_includes text, "Found 2"
      end

      test "call search_memory searches SOUL.md" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I am a helpful assistant.")

        result = @handler.call("search_memory", { "query" => "helpful" })

        text = result[:content].first[:text]
        assert_includes text, "Found"
        assert_includes text, "SOUL.md"
      end

      test "call search_memory searches USER.md" do
        File.write(File.join(@tmp_dir, "USER.md"), "Eric likes dark mode.")

        result = @handler.call("search_memory", { "query" => "dark mode" })

        text = result[:content].first[:text]
        assert_includes text, "Found"
        assert_includes text, "USER.md"
      end

      test "call search_memory uses singular memory for one result" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I am unique.")

        result = @handler.call("search_memory", { "query" => "unique" })

        text = result[:content].first[:text]
        assert_includes text, "Found 1 memory"
      end

      test "call search_memory uses plural memories for multiple results" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "Ruby is great.\nRuby is fun.\n")

        result = @handler.call("search_memory", { "query" => "Ruby" })

        text = result[:content].first[:text]
        assert_includes text, "Found 2 memories"
      end

      # --- handler without default username ---

      test "call with unknown tool name returns nil" do
        result = @handler.call("unknown_tool", {})
        assert_nil result
      end

      test "save_memory with no username falls back to unknown" do
        handler = Earl::Mcp::MemoryHandler.new(store: @store)
        handler.call("save_memory", { "text" => "Anonymous fact" })

        today = Time.now.utc.strftime("%Y-%m-%d")
        path = File.join(@tmp_dir, "#{today}.md")
        assert_includes File.read(path), "@unknown"
      end
    end
  end
end
