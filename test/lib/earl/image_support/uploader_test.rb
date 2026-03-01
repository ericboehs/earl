# frozen_string_literal: true

require "test_helper"
require "tempfile"

module Earl
  module ImageSupport
    class UploaderTest < Minitest::Test
      setup do
        Earl.logger = Logger.new(File::NULL)
        @mock_mm = build_mock_mattermost
        @context = Uploader::UploadContext.new(mattermost: @mock_mm, channel_id: "ch-1")
      end

      teardown do
        Earl.logger = nil
      end

      # --- read_image_content ---

      test "reads file_path source from disk" do
        tmp = Tempfile.new(%w[test .png])
        tmp.write("png bytes")
        tmp.close

        ref = build_ref(source: :file_path, data: tmp.path)
        assert_equal "png bytes", Uploader.read_image_content(ref)
      ensure
        tmp&.unlink
      end

      test "decodes base64 source" do
        encoded = Base64.encode64("hello image")
        ref = build_ref(source: :base64, data: encoded)
        assert_equal "hello image", Uploader.read_image_content(ref)
      end

      test "returns nil when file does not exist" do
        ref = build_ref(source: :file_path, data: "/no/such/file.png")
        assert_nil Uploader.read_image_content(ref)
      end

      # --- upload_image_ref ---

      test "uploads ref and returns file_id" do
        tmp = Tempfile.new(%w[test .png])
        tmp.write("fake png")
        tmp.close

        uploaded = []
        stub_singleton(@mock_mm, :upload_file) do |upload|
          uploaded << upload
          { "file_infos" => [{ "id" => "file-42" }] }
        end

        ref = build_ref(source: :file_path, data: tmp.path)
        result = Uploader.upload_image_ref(@context, ref)

        assert_equal "file-42", result
        assert_equal 1, uploaded.size
        assert_equal "ch-1", uploaded.first.channel_id
      ensure
        tmp&.unlink
      end

      test "returns nil when content unreadable" do
        ref = build_ref(source: :file_path, data: "/nonexistent.png")
        assert_nil Uploader.upload_image_ref(@context, ref)
      end

      test "returns nil when upload yields no file_infos" do
        tmp = Tempfile.new(%w[test .png])
        tmp.write("data")
        tmp.close

        stub_singleton(@mock_mm, :upload_file) { |_u| { "file_infos" => [] } }

        ref = build_ref(source: :file_path, data: tmp.path)
        assert_nil Uploader.upload_image_ref(@context, ref)
      ensure
        tmp&.unlink
      end

      # --- upload_refs ---

      test "uploads multiple refs and returns file_ids" do
        files = create_temp_files(2)

        counter = 0
        stub_singleton(@mock_mm, :upload_file) do |_u|
          counter += 1
          { "file_infos" => [{ "id" => "file-#{counter}" }] }
        end

        refs = files.map { |f| build_ref(source: :file_path, data: f.path) }
        result = Uploader.upload_refs(@context, refs)

        assert_equal %w[file-1 file-2], result
      ensure
        files&.each(&:unlink)
      end

      test "filters out failed uploads" do
        tmp = Tempfile.new(%w[test .png])
        tmp.write("ok")
        tmp.close

        stub_singleton(@mock_mm, :upload_file) do |_u|
          { "file_infos" => [{ "id" => "file-1" }] }
        end

        refs = [
          build_ref(source: :file_path, data: "/nonexistent.png"),
          build_ref(source: :file_path, data: tmp.path)
        ]
        result = Uploader.upload_refs(@context, refs)

        assert_equal %w[file-1], result
      ensure
        tmp&.unlink
      end

      # --- post_with_images ---

      test "creates post with file_ids" do
        posted = []
        stub_singleton(@mock_mm, :create_post_with_files) do |file_post|
          posted << file_post
          { "id" => "post-1" }
        end

        Uploader.post_with_images(@context, root_id: "thread-1", file_ids: %w[f1 f2])

        assert_equal 1, posted.size
        assert_equal "ch-1", posted.first.channel_id
        assert_equal "thread-1", posted.first.root_id
        assert_equal %w[f1 f2], posted.first.file_ids
        assert_equal "", posted.first.message
      end

      test "returns nil when file_ids is empty" do
        result = Uploader.post_with_images(@context, root_id: "thread-1", file_ids: [])
        assert_nil result
      end

      private

      def build_mock_mattermost
        mock = Object.new
        stub_singleton(mock, :upload_file) { |_u| { "file_infos" => [] } }
        stub_singleton(mock, :create_post_with_files) { |_fp| {} }
        mock
      end

      def build_ref(source:, data:, media_type: "image/png", filename: "test.png")
        OutputDetector::ImageReference.new(
          source: source, data: data, media_type: media_type, filename: filename
        )
      end

      def create_temp_files(count)
        count.times.map do |i|
          tmp = Tempfile.new(["test#{i}", ".png"])
          tmp.write("data-#{i}")
          tmp.close
          tmp
        end
      end
    end
  end
end
