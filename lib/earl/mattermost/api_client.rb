# frozen_string_literal: true

module Earl
  class Mattermost
    # Handles HTTP requests to the Mattermost REST API, encapsulating
    # authentication, connection setup, and JSON serialization.
    class ApiClient
      include Logging

      def initialize(config)
        @config = config
      end

      def post(path, body)
        request(Net::HTTP::Post, path, body)
      end

      def put(path, body)
        request(Net::HTTP::Put, path, body)
      end

      private

      def request(method_class, path, body)
        uri = URI.parse(@config.api_url(path))
        req = build_request(method_class, uri, body)
        response = send_request(uri, req)

        unless response.is_a?(Net::HTTPSuccess)
          log(:error, "Mattermost API #{req.method} #{path} failed: #{response.code} #{response.body[0..200]}")
        end

        response
      end

      def build_request(method_class, uri, body)
        req = method_class.new(uri)
        req["Authorization"] = "Bearer #{@config.bot_token}"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        req
      end

      def send_request(uri, req)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = @config.mattermost_url.start_with?("https")
        http.open_timeout = 10
        http.read_timeout = 15
        http.request(req)
      end
    end
  end
end
