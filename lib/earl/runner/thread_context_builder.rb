# frozen_string_literal: true

module Earl
  class Runner
    # Builds contextual messages for new Claude sessions by prepending
    # Mattermost thread transcripts so Claude has conversation history.
    # When prior posts include images, returns multimodal content blocks.
    class ThreadContextBuilder
      MAX_PRIOR_POSTS = 20

      def initialize(mattermost:, content_builder: nil)
        @mattermost = mattermost
        @content_builder = content_builder
      end

      # When a Claude session is first created for a thread that already has messages
      # (e.g., from !commands and EARL replies), prepend the thread transcript so
      # Claude has context. Returns a string or content block array.
      def build(thread_id, text)
        prior_posts = fetch_prior_posts(thread_id, text)
        return text if prior_posts.empty?

        build_context(prior_posts, text)
      end

      private

      def fetch_prior_posts(thread_id, current_text)
        posts = @mattermost.get_thread_posts(thread_id)
        posts.reject { |post| post[:message] == current_text }.last(MAX_PRIOR_POSTS)
      end

      def build_context(posts, text)
        return text_context(posts, text) unless images_in_posts?(posts)

        multimodal_context(posts, text)
      end

      def images_in_posts?(posts)
        @content_builder && posts.any? { |post| post[:file_ids]&.any? }
      end

      def text_context(posts, text)
        transcript = posts.map { |post| format_post(post) }.join("\n\n")
        "Here is the conversation so far in this Mattermost thread:\n\n#{transcript}\n\n" \
          "---\n\nUser's latest message: #{text}"
      end

      # Multimodal context: interleaves text and image blocks.
      module MultimodalContext
        private

        def multimodal_context(posts, text)
          blocks = [preamble_block]
          posts.each { |post| append_post_blocks(blocks, post) }
          blocks << separator_block(text)
          blocks
        end

        def preamble_block
          { "type" => "text", "text" => "Here is the conversation so far in this Mattermost thread:\n" }
        end

        def separator_block(text)
          { "type" => "text", "text" => "\n---\n\nUser's latest message: #{text}" }
        end

        def append_post_blocks(blocks, post)
          role, message, file_ids = post.values_at(:is_bot, :message, :file_ids)
          label = role ? "EARL" : "User"
          blocks << { "type" => "text", "text" => "\n#{label}: #{message}" }
          append_image_blocks(blocks, file_ids)
        end

        def append_image_blocks(blocks, file_ids)
          return unless file_ids&.any?

          image_blocks = @content_builder.build("", file_ids)
          blocks.concat(image_blocks) if image_blocks.is_a?(Array)
        end
      end

      include MultimodalContext

      def format_post(post)
        role = post[:is_bot] ? "EARL" : "User"
        "#{role}: #{post[:message]}"
      end
    end
  end
end
