# frozen_string_literal: true

require "test_helper"

module Earl
  module ImageSupport
    class ContentBuilderTest < Minitest::Test
      setup do
        Earl.logger = Logger.new(File::NULL)
        @mattermost = FakeMattermost.new
        @builder = ContentBuilder.new(mattermost: @mattermost)
      end

      teardown do
        Earl.logger = nil
      end

      # --- No images ---

      test "returns plain text when file_ids is empty" do
        result = @builder.build("Hello Claude", [])
        assert_equal "Hello Claude", result
      end

      # --- Supported image types ---

      test "builds content array with single image and text" do
        @mattermost.stub_file_info("file-1", "image/png")
        @mattermost.stub_download("file-1", png_bytes)

        result = @builder.build("Describe this", ["file-1"])

        assert_instance_of Array, result
        assert_equal 2, result.size

        image_block = result[0]
        assert_equal "image", image_block["type"]
        assert_equal "base64", image_block.dig("source", "type")
        assert_equal "image/png", image_block.dig("source", "media_type")
        assert_equal Base64.strict_encode64(png_bytes), image_block.dig("source", "data")

        text_block = result[1]
        assert_equal "text", text_block["type"]
        assert_equal "Describe this", text_block["text"]
      end

      test "builds content array with multiple images" do
        @mattermost.stub_file_info("file-1", "image/jpeg")
        @mattermost.stub_file_info("file-2", "image/webp")
        @mattermost.stub_download("file-1", png_bytes)
        @mattermost.stub_download("file-2", png_bytes)

        result = @builder.build("Two images", %w[file-1 file-2])

        assert_instance_of Array, result
        assert_equal 3, result.size
        assert_equal "image", result[0]["type"]
        assert_equal "image/jpeg", result[0].dig("source", "media_type")
        assert_equal "image", result[1]["type"]
        assert_equal "image/webp", result[1].dig("source", "media_type")
        assert_equal "text", result[2]["type"]
      end

      test "omits text block when text is empty" do
        @mattermost.stub_file_info("file-1", "image/png")
        @mattermost.stub_download("file-1", png_bytes)

        result = @builder.build("", ["file-1"])

        assert_instance_of Array, result
        assert_equal 1, result.size
        assert_equal "image", result[0]["type"]
      end

      # --- Unsupported types ---

      test "skips unsupported MIME types and returns plain text" do
        @mattermost.stub_file_info("file-1", "application/pdf")

        result = @builder.build("Check this PDF", ["file-1"])

        assert_equal "Check this PDF", result
      end

      test "skips SVG images since Claude cannot process vector graphics" do
        @mattermost.stub_file_info("file-1", "image/svg+xml")

        result = @builder.build("See this SVG", ["file-1"])

        assert_equal "See this SVG", result
      end

      test "skips unsupported MIME types but keeps supported ones" do
        @mattermost.stub_file_info("file-1", "application/pdf")
        @mattermost.stub_file_info("file-2", "image/gif")
        @mattermost.stub_download("file-2", png_bytes)

        result = @builder.build("Mixed files", %w[file-1 file-2])

        assert_instance_of Array, result
        assert_equal 2, result.size
        assert_equal "image", result[0]["type"]
        assert_equal "image/gif", result[0].dig("source", "media_type")
      end

      # --- Size limit ---

      test "skips files exceeding 5MB" do
        @mattermost.stub_file_info("file-1", "image/png")
        @mattermost.stub_download("file-1", "x" * ((5 * 1024 * 1024) + 1))

        result = @builder.build("Big image", ["file-1"])

        assert_equal "Big image", result
      end

      test "accepts files at exactly 5MB" do
        data = "x" * (5 * 1024 * 1024)
        @mattermost.stub_file_info("file-1", "image/png")
        @mattermost.stub_download("file-1", data)

        result = @builder.build("Exact limit", ["file-1"])

        assert_instance_of Array, result
        assert_equal 2, result.size
      end

      # --- Download failures ---

      test "skips files that fail to download" do
        @mattermost.stub_file_info("file-1", "image/png")
        @mattermost.stub_download_failure("file-1")

        result = @builder.build("Broken download", ["file-1"])

        assert_equal "Broken download", result
      end

      test "skips failed downloads but keeps successful ones" do
        @mattermost.stub_file_info("file-1", "image/png")
        @mattermost.stub_file_info("file-2", "image/jpeg")
        @mattermost.stub_download_failure("file-1")
        @mattermost.stub_download("file-2", png_bytes)

        result = @builder.build("Partial success", %w[file-1 file-2])

        assert_instance_of Array, result
        assert_equal 2, result.size
        assert_equal "image", result[0]["type"]
        assert_equal "image/jpeg", result[0].dig("source", "media_type")
      end

      # --- All supported MIME types ---

      test "supports image/jpeg" do
        assert_supports_mime("image/jpeg")
      end

      test "supports image/png" do
        assert_supports_mime("image/png")
      end

      test "supports image/gif" do
        assert_supports_mime("image/gif")
      end

      test "supports image/webp" do
        assert_supports_mime("image/webp")
      end

      private

      def png_bytes
        @png_bytes ||= "\x89PNG\r\n\u001A\n#{"pixel" * 10}"
      end

      def assert_supports_mime(mime_type)
        @mattermost.stub_file_info("file-1", mime_type)
        @mattermost.stub_download("file-1", png_bytes)

        result = @builder.build("test", ["file-1"])

        assert_instance_of Array, result
        assert_equal mime_type, result[0].dig("source", "media_type")
      end

      # Minimal fake Mattermost for testing ContentBuilder
      class FakeMattermost
        def initialize
          @file_infos = {}
          @downloads = {}
        end

        def stub_file_info(file_id, mime_type)
          @file_infos[file_id] = { "mime_type" => mime_type }
        end

        def stub_download(file_id, body)
          response = Object.new
          stub_singleton(response, :body) { body }
          stub_singleton(response, :is_a?) do |klass|
            klass == Net::HTTPSuccess || Object.instance_method(:is_a?).bind_call(self, klass)
          end
          @downloads[file_id] = response
        end

        def stub_download_failure(file_id)
          response = Object.new
          stub_singleton(response, :body) { "" }
          stub_singleton(response, :code) { "500" }
          stub_singleton(response, :is_a?) do |klass|
            Object.instance_method(:is_a?).bind_call(self, klass)
          end
          @downloads[file_id] = response
        end

        def get_file_info(file_id)
          @file_infos.fetch(file_id, {})
        end

        def download_file(file_id)
          @downloads.fetch(file_id)
        end
      end
    end
  end
end
