# frozen_string_literal: true

module Earl
  module Mcp
    # MCP handler exposing Mattermost thread fetching tools.
    # Allows Claude sessions to retrieve thread transcripts by post_id,
    # enabling conversation analysis and cross-thread references.
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class MattermostHandler
      include Logging
      include HandlerBase

      TOOL_NAMES = %w[get_thread_content].freeze
      POST_ID_DESCRIPTION = "The Mattermost post ID. Extract from permalink URLs " \
                            "(e.g., https://mm.boehs.com/boehs/pl/<post_id>)"

      def initialize(api_client:)
        @api = api_client
      end

      def tool_definitions
        [thread_content_definition]
      end

      def call(name, arguments)
        return unless handles?(name)

        handle_get_thread(arguments)
      end

      private

      def handle_get_thread(arguments)
        post_id = arguments["post_id"].to_s.strip
        return text_content("Error: post_id is required") if post_id.empty?

        thread_id = resolve_thread_id(post_id)
        return text_content("Error: could not fetch post #{post_id}") unless thread_id

        fetch_thread_transcript(thread_id, post_id)
      end

      def fetch_thread_transcript(thread_id, post_id)
        result = fetch_thread(thread_id)
        return text_content(result) if result.is_a?(String)
        return text_content("No messages found in thread #{post_id}") if result.empty?

        text_content(format_transcript(result))
      end

      # Fetches a single post to find its root thread ID.
      # If the post has no root_id, it is the root post itself.
      def resolve_thread_id(post_id)
        body = fetch_post_body(post_id)
        return nil unless body

        root_id = JSON.parse(body)["root_id"]
        root_id.to_s.empty? ? post_id : root_id
      rescue JSON::ParserError => error
        log(:warn, "Failed to parse post #{post_id}: #{error.message}")
        nil
      end

      def fetch_post_body(post_id)
        successful_body(@api.get("/posts/#{post_id}"))
      end

      def successful_body(response)
        response.body if response.is_a?(Net::HTTPSuccess)
      end

      def fetch_thread(thread_id)
        response = @api.get("/posts/#{thread_id}/thread")
        unless response.is_a?(Net::HTTPSuccess)
          return "Error: failed to fetch thread #{thread_id} (HTTP #{response.code})"
        end

        data = JSON.parse(response.body)
        posts, order = data.values_at("posts", "order")
        build_posts(posts || {}, order || [])
      rescue JSON::ParserError => error
        log(:warn, "Failed to parse thread: #{error.message}")
        []
      end

      # Thread post parsing and formatting.
      module TranscriptFormatting
        MAX_POSTS = 50

        private

        def build_posts(posts, order)
          ids = order.reverse.last(MAX_POSTS)
          resolved = ids.filter_map { |id| posts[id] }
          resolved.map { |entry| format_post(entry) }
        end

        def format_post(post)
          message, create_at, props = post.values_at("message", "create_at", "props")
          sender = extract_sender(props)

          "[#{format_timestamp(create_at)}] #{sender}: #{message || ""}"
        end

        def extract_sender(props)
          props.is_a?(Hash) && props["from_bot"] == "true" ? "EARL" : "User"
        end

        def format_timestamp(create_at)
          return "unknown" unless create_at.is_a?(Integer)

          Time.at(create_at / 1000).strftime("%Y-%m-%d %H:%M:%S")
        end

        def format_transcript(posts)
          header = "**Thread transcript** (#{posts.size} messages):\n\n"
          header + posts.join("\n\n")
        end
      end

      include TranscriptFormatting

      def text_content(text)
        { content: [{ type: "text", text: text }] }
      end

      def thread_content_definition
        {
          name: "get_thread_content",
          description: thread_content_description,
          inputSchema: post_id_schema
        }
      end

      def thread_content_description
        "Fetch the full transcript of a Mattermost thread by post ID. " \
          "Use this when you need to read or analyze a conversation thread. " \
          "The post_id can be any post in the thread (root or reply)."
      end

      def post_id_schema
        {
          type: "object",
          properties: {
            post_id: { type: "string", description: POST_ID_DESCRIPTION }
          },
          required: %w[post_id]
        }
      end
    end
  end
end
