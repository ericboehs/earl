# frozen_string_literal: true

require "test_helper"

module Earl
  module Memory
    class PromptBuilderTest < Minitest::Test
      setup do
        @tmp_dir = Dir.mktmpdir("earl-memory-prompt-test")
      end

      teardown do
        FileUtils.rm_rf(@tmp_dir)
      end

      test "build returns nil when all memory is empty" do
        store = Earl::Memory::Store.new(dir: @tmp_dir)
        builder = Earl::Memory::PromptBuilder.new(store: store)

        assert_nil builder.build
      end

      test "build includes soul section when SOUL.md exists" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I am EARL, a helpful bot.")
        store = Earl::Memory::Store.new(dir: @tmp_dir)
        builder = Earl::Memory::PromptBuilder.new(store: store)

        prompt = builder.build
        assert_includes prompt, "<earl-memory>"
        assert_includes prompt, "## Core Identity"
        assert_includes prompt, "I am EARL, a helpful bot."
        assert_includes prompt, "</earl-memory>"
      end

      test "build includes user notes section when USER.md exists" do
        File.write(File.join(@tmp_dir, "USER.md"), "Eric prefers dark mode.")
        store = Earl::Memory::Store.new(dir: @tmp_dir)
        builder = Earl::Memory::PromptBuilder.new(store: store)

        prompt = builder.build
        assert_includes prompt, "## User Notes"
        assert_includes prompt, "Eric prefers dark mode."
      end

      test "build includes recent memories section" do
        today = Date.today.strftime("%Y-%m-%d")
        File.write(File.join(@tmp_dir, "#{today}.md"),
                   "# Memories\n\n- **10:00 UTC** | `@alice` | Likes Ruby\n")
        store = Earl::Memory::Store.new(dir: @tmp_dir)
        builder = Earl::Memory::PromptBuilder.new(store: store)

        prompt = builder.build
        assert_includes prompt, "## Recent Memories"
        assert_includes prompt, "Likes Ruby"
      end

      test "build includes CLI tool instructions" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I am EARL.")
        store = Earl::Memory::Store.new(dir: @tmp_dir)
        builder = Earl::Memory::PromptBuilder.new(store: store)

        prompt = builder.build
        assert_includes prompt, "earl heartbeat"
        assert_includes prompt, "earl thread POST_ID"
      end

      test "build combines all sections" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I am EARL.")
        File.write(File.join(@tmp_dir, "USER.md"), "User likes vim.")
        today = Date.today.strftime("%Y-%m-%d")
        File.write(File.join(@tmp_dir, "#{today}.md"),
                   "# Memories\n\n- **10:00 UTC** | `@eric` | Uses Ruby\n")
        store = Earl::Memory::Store.new(dir: @tmp_dir)
        builder = Earl::Memory::PromptBuilder.new(store: store)

        prompt = builder.build
        assert_includes prompt, "## Core Identity"
        assert_includes prompt, "## User Notes"
        assert_includes prompt, "## Recent Memories"
      end

      test "build omits empty sections" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "I am EARL.")
        # No USER.md, no date files
        store = Earl::Memory::Store.new(dir: @tmp_dir)
        builder = Earl::Memory::PromptBuilder.new(store: store)

        prompt = builder.build
        assert_includes prompt, "## Core Identity"
        assert_not_includes prompt, "## User Notes"
        assert_not_includes prompt, "## Recent Memories"
      end

      test "build strips whitespace from sections" do
        File.write(File.join(@tmp_dir, "SOUL.md"), "\n  I am EARL.  \n\n")
        store = Earl::Memory::Store.new(dir: @tmp_dir)
        builder = Earl::Memory::PromptBuilder.new(store: store)

        prompt = builder.build
        assert_includes prompt, "I am EARL."
        # Should not have leading/trailing whitespace in section content
        assert_not_includes prompt, "## Core Identity\n\n  I am EARL."
      end
    end
  end
end
