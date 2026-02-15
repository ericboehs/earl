# frozen_string_literal: true

module Earl
  module Memory
    # Builds the --append-system-prompt text from memory files.
    # Combines SOUL.md, USER.md, and recent episodic memories into a single
    # prompt string wrapped in <earl-memory> tags.
    class PromptBuilder
      def initialize(store:)
        @store = store
      end

      def build
        sections = build_sections
        return nil if sections.empty?

        "<earl-memory>\n#{sections.join("\n\n")}\n</earl-memory>\n\n" \
          "You have persistent memory via save_memory and search_memory tools.\n" \
          "Save important facts you learn. Search when you need to recall something."
      end

      private

      def build_sections
        sections = []
        append_section(sections, "Core Identity", @store.soul)
        append_section(sections, "User Notes", @store.users)
        append_section(sections, "Recent Memories", @store.recent_memories)
        sections
      end

      def append_section(sections, heading, content)
        stripped = content.to_s.strip
        return if stripped.empty?

        sections << "## #{heading}\n#{stripped}"
      end
    end
  end
end
