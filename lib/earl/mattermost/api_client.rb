# frozen_string_literal: true

module Earl
  class Mattermost
    # Handles HTTP requests to the Mattermost REST API, encapsulating
    # authentication, connection setup, and JSON serialization.
    class ApiClient
      include Logging

      # Encapsulates an HTTP request's method, path, and body.
      Request = Struct.new(:method_class, :path, :body, keyword_init: true)

      def initialize(config)
        @config = config
      end

      def post(path, body)
        execute(Request.new(method_class: Net::HTTP::Post, path: path, body: body))
      end

      def put(path, body)
        execute(Request.new(method_class: Net::HTTP::Put, path: path, body: body))
      end

      private

      def execute(request)
        uri = URI.parse(@config.api_url(request.path))
        http_req = build_request(request.method_class, uri, request.body)
        response = send_request(uri, http_req)

        unless response.is_a?(Net::HTTPSuccess)
          log(:error, "Mattermost API #{http_req.method} #{uri.path} failed: #{response.code} #{response.body[0..200]}")
        end

        response
      end

      # :reek:FeatureEnvy
      def build_request(method_class, uri, body)
        req = method_class.new(uri)
        req["Authorization"] = "Bearer #{@config.bot_token}"
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
        req
      end

      # :reek:FeatureEnvy
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
