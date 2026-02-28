# frozen_string_literal: true

require "test_helper"

module Earl
  class Runner
    class ThreadContextBuilderTest < Minitest::Test
      setup do
        Earl.logger = Logger.new(File::NULL)
        @mattermost = FakeMattermost.new
      end

      teardown do
        Earl.logger = nil
      end

      # --- Text-only context ---

      test "returns plain text when no prior posts" do
        @mattermost.stub_thread([])
        builder = ThreadContextBuilder.new(mattermost: @mattermost)

        result = builder.build("thread-1", "hello")

        assert_equal "hello", result
      end

      test "builds text context from prior posts" do
        posts = [
          { sender: "user", message: "!help", is_bot: false, file_ids: [] },
          { sender: "EARL", message: "Available commands", is_bot: true, file_ids: [] }
        ]
        @mattermost.stub_thread(posts)
        builder = ThreadContextBuilder.new(mattermost: @mattermost)

        result = builder.build("thread-1", "thanks")

        assert_instance_of String, result
        assert_includes result, "User: !help"
        assert_includes result, "EARL: Available commands"
        assert_includes result, "User's latest message: thanks"
      end

      test "excludes current message from transcript" do
        posts = [
          { sender: "user", message: "first", is_bot: false, file_ids: [] },
          { sender: "user", message: "thanks", is_bot: false, file_ids: [] }
        ]
        @mattermost.stub_thread(posts)
        builder = ThreadContextBuilder.new(mattermost: @mattermost)

        result = builder.build("thread-1", "thanks")

        assert_includes result, "User: first"
        assert_not_includes result, "User: thanks\n"
        assert_includes result, "User's latest message: thanks"
      end

      test "limits to MAX_PRIOR_POSTS" do
        posts = (1..25).map do |index|
          { sender: "user", message: "msg-#{index}", is_bot: false, file_ids: [] }
        end
        @mattermost.stub_thread(posts)
        builder = ThreadContextBuilder.new(mattermost: @mattermost)

        result = builder.build("thread-1", "new message")

        # Should include last 20 posts (msg-6 through msg-25)
        assert_not_includes result, "msg-5"
        assert_includes result, "msg-6"
        assert_includes result, "msg-25"
      end

      # --- Multimodal context (posts with images) ---

      test "returns text context when no content_builder provided even with images" do
        posts = [
          { sender: "user", message: "look at this", is_bot: false, file_ids: ["file-1"] }
        ]
        @mattermost.stub_thread(posts)
        builder = ThreadContextBuilder.new(mattermost: @mattermost)

        result = builder.build("thread-1", "what is it?")

        assert_instance_of String, result
        assert_includes result, "User: look at this"
      end

      test "returns content blocks when posts have images and content_builder provided" do
        posts = [
          { sender: "user", message: "see this image", is_bot: false, file_ids: ["file-1"] },
          { sender: "EARL", message: "I see a cat", is_bot: true, file_ids: [] }
        ]
        @mattermost.stub_thread(posts)
        content_builder = FakeContentBuilder.new
        builder = ThreadContextBuilder.new(mattermost: @mattermost, content_builder: content_builder)

        result = builder.build("thread-1", "describe more")

        assert_instance_of Array, result
        # Preamble block
        assert_equal "text", result[0]["type"]
        assert_includes result[0]["text"], "conversation so far"
        # User message block
        assert_equal "text", result[1]["type"]
        assert_includes result[1]["text"], "User: see this image"
        # Image block from content_builder
        assert_equal "image", result[2]["type"]
        # EARL message block
        assert_equal "text", result[3]["type"]
        assert_includes result[3]["text"], "EARL: I see a cat"
        # Separator block
        last_block = result.last
        assert_equal "text", last_block["type"]
        assert_includes last_block["text"], "User's latest message: describe more"
      end

      test "skips image blocks for posts without file_ids" do
        posts = [
          { sender: "user", message: "no images here", is_bot: false, file_ids: [] },
          { sender: "user", message: "has image", is_bot: false, file_ids: ["file-1"] }
        ]
        @mattermost.stub_thread(posts)
        content_builder = FakeContentBuilder.new
        builder = ThreadContextBuilder.new(mattermost: @mattermost, content_builder: content_builder)

        result = builder.build("thread-1", "follow up")

        assert_instance_of Array, result
        image_blocks = result.select { |block| block["type"] == "image" }
        assert_equal 1, image_blocks.size
      end

      test "falls back to text when content_builder returns non-array" do
        posts = [
          { sender: "user", message: "has image", is_bot: false, file_ids: ["file-1"] }
        ]
        @mattermost.stub_thread(posts)
        content_builder = FakeContentBuilder.new(return_string: true)
        builder = ThreadContextBuilder.new(mattermost: @mattermost, content_builder: content_builder)

        result = builder.build("thread-1", "what?")

        assert_instance_of Array, result
        # Image blocks should not be concatenated when builder returns a string
        image_blocks = result.select { |block| block["type"] == "image" }
        assert_equal 0, image_blocks.size
      end

      test "builds image blocks only from posts that have file_ids, skipping posts with missing file_ids" do
        posts = [
          { sender: "user", message: "has image", is_bot: false, file_ids: ["file-1"] },
          { sender: "EARL", message: "reply", is_bot: true }
        ]
        @mattermost.stub_thread(posts)
        content_builder = FakeContentBuilder.new
        builder = ThreadContextBuilder.new(mattermost: @mattermost, content_builder: content_builder)

        result = builder.build("thread-1", "follow up")

        assert_instance_of Array, result
        image_blocks = result.select { |block| block["type"] == "image" }
        assert_equal 1, image_blocks.size
      end

      test "returns text context when no posts have images even with content_builder" do
        posts = [
          { sender: "user", message: "just text", is_bot: false, file_ids: [] },
          { sender: "EARL", message: "response", is_bot: true, file_ids: [] }
        ]
        @mattermost.stub_thread(posts)
        content_builder = FakeContentBuilder.new
        builder = ThreadContextBuilder.new(mattermost: @mattermost, content_builder: content_builder)

        result = builder.build("thread-1", "more text")

        assert_instance_of String, result
        assert_includes result, "User: just text"
        assert_includes result, "EARL: response"
      end

      # --- Fake test doubles ---

      class FakeMattermost
        def initialize
          @thread_posts = []
        end

        def stub_thread(posts)
          @thread_posts = posts
        end

        def get_thread_posts(_thread_id)
          @thread_posts
        end
      end

      class FakeContentBuilder
        def initialize(return_string: false)
          @return_string = return_string
        end

        def build(_text, file_ids)
          return "plain text" if @return_string
          return [] if file_ids.empty?

          file_ids.map do |_id|
            { "type" => "image", "source" => { "type" => "base64", "media_type" => "image/png", "data" => "abc" } }
          end
        end
      end
    end
  end
end
