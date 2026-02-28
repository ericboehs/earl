# frozen_string_literal: true

require "base64"

module Earl
  module ImageSupport
    # Detects image content in Claude's tool results and text responses.
    # Returns ImageReference objects for each detected image.
    class OutputDetector
      include Logging

      # Represents a detected image from Claude output, either a file path or base64 data.
      ImageReference = Data.define(:source, :data, :media_type, :filename)

      # Pairs a base64 detection pattern with its output metadata.
      Base64Signature = Data.define(:pattern, :media_type, :filename)

      MEDIA_TYPES = {
        ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
        ".gif" => "image/gif", ".webp" => "image/webp"
      }.freeze
      IMAGE_PATH_PATTERN = %r{(?:^|\s)(/\S+(?:\.png|\.jpe?g|\.gif|\.webp))(?:\s|$)}i

      BASE64_SIGNATURES = [
        Base64Signature.new(pattern: %r{iVBOR[A-Za-z0-9+/=]{100,}}, media_type: "image/png",
                            filename: "screenshot.png"),
        Base64Signature.new(pattern: %r{/9j/[A-Za-z0-9+/=]{100,}}, media_type: "image/jpeg",
                            filename: "screenshot.jpg")
      ].freeze

      def detect_in_tool_result(tool_name, result_text)
        return [] unless result_text.is_a?(String)

        refs = detect_file_paths(result_text)
        refs.concat(detect_base64_in_text(result_text)) if screenshot_tool?(tool_name)
        refs
      end

      def detect_in_text(text)
        return [] unless text.is_a?(String)

        detect_file_paths(text)
      end

      private

      def detect_file_paths(text)
        text.scan(IMAGE_PATH_PATTERN).filter_map do |match|
          build_file_reference(match[0])
        end
      end

      def build_file_reference(path)
        return nil unless File.exist?(path) && File.file?(path)
        return log_skip(path, "exceeds 50MB") if File.size(path) > 50 * 1024 * 1024

        ImageReference.new(
          source: :file_path, data: path,
          media_type: media_type_for(path), filename: File.basename(path)
        )
      end

      def detect_base64_in_text(text)
        BASE64_SIGNATURES.flat_map { |sig| matches_for_signature(text, sig) }
      end

      def matches_for_signature(text, sig)
        text.scan(sig.pattern).map do |match|
          ImageReference.new(source: :base64, data: match, media_type: sig.media_type, filename: sig.filename)
        end
      end

      def screenshot_tool?(tool_name)
        tool_name&.include?("screenshot") || tool_name&.include?("browser_take_screenshot")
      end

      def media_type_for(path)
        MEDIA_TYPES.fetch(File.extname(path).downcase, "application/octet-stream")
      end

      def log_skip(path, reason)
        log(:debug, "Skipping image #{path}: #{reason}")
        nil
      end
    end
  end
end
