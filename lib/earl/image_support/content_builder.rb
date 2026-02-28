# frozen_string_literal: true

require "base64"

module Earl
  module ImageSupport
    # Builds multimodal content arrays for Claude CLI stream-json input.
    # Returns a plain string when no images are present, or an array of
    # content blocks (image + text) when file attachments exist.
    class ContentBuilder
      include Logging

      SUPPORTED_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
      MAX_IMAGE_BYTES = 5 * 1024 * 1024

      def initialize(mattermost:)
        @mattermost = mattermost
      end

      def build(text, file_ids)
        return text if file_ids.empty?

        image_blocks = file_ids.filter_map { |fid| build_image_block(fid) }
        return text if image_blocks.empty?

        log(:info, "Built #{image_blocks.size} image block(s) from #{file_ids.size} file(s)")
        assemble_content(image_blocks, text)
      end

      private

      def build_image_block(file_id)
        info = @mattermost.get_file_info(file_id)
        mime_type = info["mime_type"]
        return log_skip(file_id, "unsupported type: #{mime_type}") unless SUPPORTED_TYPES.include?(mime_type)

        download_and_encode(file_id, mime_type)
      end

      def download_and_encode(file_id, mime_type)
        response = @mattermost.download_file(file_id)
        return log_skip(file_id, "download failed") unless response.is_a?(Net::HTTPSuccess)

        body = response.body
        size = body.bytesize
        return log_skip(file_id, "exceeds 5MB (#{size} bytes)") if size > MAX_IMAGE_BYTES

        encode_block(body, mime_type)
      end

      def encode_block(body, mime_type)
        {
          "type" => "image",
          "source" => {
            "type" => "base64",
            "media_type" => mime_type,
            "data" => Base64.strict_encode64(body)
          }
        }
      end

      def assemble_content(image_blocks, text)
        blocks = image_blocks.dup
        blocks << { "type" => "text", "text" => text } unless text.empty?
        blocks
      end

      def log_skip(file_id, reason)
        log(:debug, "Skipping file #{file_id}: #{reason}")
        nil
      end
    end
  end
end
