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

      def get(path)
        execute(Request.new(method_class: Net::HTTP::Get, path: path, body: nil))
      end

      def post(path, body)
        execute(Request.new(method_class: Net::HTTP::Post, path: path, body: body))
      end

      def put(path, body)
        execute(Request.new(method_class: Net::HTTP::Put, path: path, body: body))
      end

      def delete(path)
        execute(Request.new(method_class: Net::HTTP::Delete, path: path, body: nil))
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
        if body
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body)
        end
        req
      end

      MAX_RETRIES = 2
      RETRY_DELAY = 1

      # :reek:FeatureEnvy
      def send_request(uri, req)
        attempts = 0
        begin
          attempts += 1
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = @config.mattermost_url.start_with?("https")
          http.open_timeout = 10
          http.read_timeout = 15
          http.request(req)
        rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, IOError => error
          raise if attempts > MAX_RETRIES

          log(:warn, "Mattermost API retry #{attempts}/#{MAX_RETRIES} after #{error.class}: #{error.message}")
          sleep RETRY_DELAY
          retry
        end
      end
    end
  end
end
