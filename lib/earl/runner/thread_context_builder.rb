# frozen_string_literal: true

module Earl
  class Runner
    # Builds contextual messages for new Claude sessions by prepending
    # Mattermost thread transcripts so Claude has conversation history.
    class ThreadContextBuilder
      MAX_PRIOR_POSTS = 20

      def initialize(mattermost:)
        @mattermost = mattermost
      end

      # When a Claude session is first created for a thread that already has messages
      # (e.g., from !commands and EARL replies), prepend the thread transcript so
      # Claude has context. Returns the original text if no prior messages exist.
      def build(thread_id, text)
        prior_posts = fetch_prior_posts(thread_id, text)
        return text if prior_posts.empty?

        transcript = format_transcript(prior_posts)
        "Here is the conversation so far in this Mattermost thread:\n\n#{transcript}\n\n" \
          "---\n\nUser's latest message: #{text}"
      end

      private

      def fetch_prior_posts(thread_id, current_text)
        posts = @mattermost.get_thread_posts(thread_id)
        posts.reject { |post| post[:message] == current_text }.last(MAX_PRIOR_POSTS)
      end

      def format_transcript(posts)
        posts.map { |post| format_post(post) }.join("\n\n")
      end

      def format_post(post)
        role = post[:is_bot] ? "EARL" : "User"
        "#{role}: #{post[:message]}"
      end
    end
  end
end
