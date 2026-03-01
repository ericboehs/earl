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
        ".gif" => "image/gif", ".webp" => "image/webp", ".svg" => "image/svg+xml"
      }.freeze
      IMAGE_PATH_PATTERN =
        %r{(?:^|[\s`*\[("])(/[^\s`*\])"',]+(?:\.png|\.jpe?g|\.gif|\.webp|\.svg))(?:[\s`*\])",.:;!?]|$)}i
      RELATIVE_IMAGE_PATTERN = %r{
        (?:^|[\s`*\[("]) # leading context
        (\.?[a-zA-Z0-9_.-]+/[^\s`*\])"',]+(?:\.png|\.jpe?g|\.gif|\.webp|\.svg)) # relative path
        (?:[\s`*\])",.:;!?]|$) # trailing context
      }ix

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

      def detect_in_text(text) = text.is_a?(String) ? detect_file_paths(text) : []

      def detect_inline_images(image_blocks, texts: [], working_dir: nil)
        return [] unless image_blocks.is_a?(Array) || texts.is_a?(Array)

        file_refs = scan_texts_for_paths(Array(texts), working_dir)
        unless file_refs.empty?
          log_image_count(file_refs.size)
          return file_refs
        end

        refs = Array(image_blocks).filter_map { |block| build_inline_reference(block) }
        log_image_count(refs.size) unless refs.empty?
        refs
      end

      private

      def detect_file_paths(text)
        text.scan(IMAGE_PATH_PATTERN).filter_map { |match| build_file_reference(match[0]) }
      end

      def scan_texts_for_paths(texts, working_dir)
        texts.flat_map { |text| detect_paths_with_resolve(text, working_dir) }
      end

      def detect_paths_with_resolve(text, working_dir)
        abs_refs = detect_file_paths(text)
        rel_refs = resolve_relative_paths(text, working_dir)
        abs_refs.concat(rel_refs)
      end

      def resolve_relative_paths(text, working_dir)
        return [] unless working_dir

        text.scan(RELATIVE_IMAGE_PATTERN).filter_map do |match|
          resolved = File.expand_path(match[0], working_dir)
          build_file_reference(resolved)
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

      def build_inline_reference(block)
        source = block["source"] || {}
        base64_data = source["data"]
        return nil unless base64_data.is_a?(String) && base64_data.size > 100

        media_type = source["media_type"] || infer_media_type(base64_data)
        ImageReference.new(
          source: :base64, data: base64_data,
          media_type: media_type, filename: inline_filename(media_type)
        )
      end

      def infer_media_type(base64_data)
        return "image/jpeg" if base64_data.start_with?("/9j/")

        "image/png"
      end

      def inline_filename(media_type) = "screenshot#{MEDIA_TYPES.key(media_type) || ".png"}"

      def media_type_for(path) = MEDIA_TYPES.fetch(File.extname(path).downcase, "application/octet-stream")

      def log_image_count(count)
        log(:info, "Detected #{count} image(s) in tool result")
      end

      def log_skip(path, reason)
        log(:debug, "Skipping image #{path}: #{reason}")
        nil
      end
    end
  end
end
