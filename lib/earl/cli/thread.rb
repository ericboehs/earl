# frozen_string_literal: true

module Earl
  module Cli
    # CLI handler for `earl thread POST_ID`.
    # Fetches and prints a Mattermost thread transcript to stdout.
    # Reuses TranscriptFormatting from MattermostHandler.
    class Thread
      include Mcp::MattermostHandler::TranscriptFormatting

      def self.run(argv)
        new.run(argv)
      end

      def initialize(api_client: nil)
        @api_client = api_client
      end

      def run(argv)
        post_id = argv[0].to_s.strip
        abort "Usage: earl thread POST_ID" if post_id.empty?

        thread_id = resolve_thread_id(post_id)
        abort "Error: could not fetch post #{post_id}" unless thread_id

        print_thread(thread_id, post_id)
      end

      private

      def api_client
        @api_client ||= build_api_client
      end

      def build_api_client
        url = ENV.fetch("MATTERMOST_URL") { abort "Missing MATTERMOST_URL" }
        token = ENV.fetch("MATTERMOST_BOT_TOKEN") { abort "Missing MATTERMOST_BOT_TOKEN" }
        config = Earl::Mcp::Config::ApiConfig.new(mattermost_url: url, bot_token: token, bot_id: nil)
        Earl::Mattermost::ApiClient.new(config)
      end

      def resolve_thread_id(post_id)
        body = successful_body(api_client.get("/posts/#{post_id}"))
        return nil unless body

        root_id = JSON.parse(body)["root_id"]
        root_id.to_s.empty? ? post_id : root_id
      rescue JSON::ParserError
        nil
      end

      def successful_body(response)
        response.body if response.is_a?(Net::HTTPSuccess)
      end

      def print_thread(thread_id, post_id)
        posts = fetch_thread(thread_id)
        abort posts if posts.is_a?(String)
        abort "No messages found in thread #{post_id}" if posts.empty?

        puts format_transcript(posts)
      end

      def fetch_thread(thread_id)
        body = successful_body(api_client.get("/posts/#{thread_id}/thread"))
        return "Error: failed to fetch thread #{thread_id}" unless body

        data = JSON.parse(body)
        posts, order = data.values_at("posts", "order")
        build_posts(posts || {}, order || [])
      rescue JSON::ParserError
        []
      end
    end
  end
end
