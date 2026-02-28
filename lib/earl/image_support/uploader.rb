# frozen_string_literal: true

require "base64"

module Earl
  module ImageSupport
    # Uploads detected images to Mattermost and posts them as file attachments.
    # Accepts an UploadContext bundling the mattermost client and channel ID.
    # Used by both StreamingResponse and PearlHandler.
    module Uploader
      # Bundles the Mattermost client and channel ID that travel together
      # through all upload operations.
      UploadContext = Data.define(:mattermost, :channel_id)

      module_function

      def read_image_content(ref)
        data = ref.data
        ref.source == :file_path ? File.binread(data) : Base64.decode64(data)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR, IOError => error
        Earl.logger.warn("Uploader: failed to read image #{ref.filename}: #{error.message}")
        nil
      end

      def upload_image_ref(context, ref)
        content = read_image_content(ref)
        return nil unless content

        filename = ref.filename
        upload = Mattermost::ApiClient::FileUpload.new(
          channel_id: context.channel_id, filename: filename, content: content, content_type: ref.media_type
        )
        file_id = context.mattermost.upload_file(upload).dig("file_infos", 0, "id")
        Earl.logger.warn("Uploader: upload returned no file_id for #{filename}") unless file_id
        file_id
      end

      def upload_refs(context, refs)
        refs.filter_map { |ref| upload_image_ref(context, ref) }
      end

      def post_with_images(context, root_id:, file_ids:)
        return nil if file_ids.empty?

        file_post = Mattermost::FileHandling::FilePost.new(
          channel_id: context.channel_id, message: "",
          root_id: root_id, file_ids: file_ids
        )
        context.mattermost.create_post_with_files(file_post)
      end
    end
  end
end
