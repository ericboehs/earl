# frozen_string_literal: true

module Earl
  module Mcp
    class ConversationHandler
      # Fetches and formats Mattermost thread posts into a readable transcript.
      module TranscriptFormatter
        MAX_POSTS = 100
        MAX_TRANSCRIPT_CHARS = 50_000

        private

        def fetch_and_format_transcript(thread_id)
          posts = fetch_thread_posts(thread_id)
          return "No posts found in thread." if posts.empty?

          transcript = format_posts(posts)
          truncate_transcript(transcript)
        end

        def fetch_thread_posts(thread_id)
          response = @api.get("/posts/#{thread_id}/thread")
          return [] unless response.is_a?(Net::HTTPSuccess)

          data = JSON.parse(response.body)
          posts, order = data.values_at("posts", "order")
          build_ordered_posts(posts || {}, order || [])
        rescue JSON::ParserError
          []
        end

        def build_ordered_posts(posts, order)
          ordered_ids = order.reverse.last(MAX_POSTS)
          ordered_ids.filter_map { |id| format_thread_post(posts.fetch(id, nil)) }
        end

        def format_thread_post(post)
          return nil unless post

          create_at, message = post.values_at("create_at", "message")
          {
            timestamp: format_timestamp(create_at),
            role: resolve_role(post),
            message: message || ""
          }
        end

        def format_timestamp(create_at)
          return "unknown" unless create_at

          Time.at(create_at / 1000).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
        end

        def resolve_role(post)
          return "EARL" if post.dig("props", "from_bot") == "true"

          bot_id = ENV.fetch("MATTERMOST_BOT_ID", nil)
          return "EARL" if bot_id && post["user_id"] == bot_id

          "User"
        end

        def format_posts(posts)
          posts.map { |post| format_post_line(post) }.join("\n")
        end

        def format_post_line(post)
          "[#{post[:timestamp]}] #{post[:role]}: #{post[:message]}"
        end

        def truncate_transcript(transcript)
          return transcript if transcript.length <= MAX_TRANSCRIPT_CHARS

          transcript[0, MAX_TRANSCRIPT_CHARS] + "\n\n[Transcript truncated at #{MAX_TRANSCRIPT_CHARS} characters]"
        end
      end
    end
  end
end
