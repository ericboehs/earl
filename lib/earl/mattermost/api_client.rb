# frozen_string_literal: true

module Earl
  class Mattermost
    # Handles HTTP requests to the Mattermost REST API, encapsulating
    # authentication, connection setup, and JSON serialization.
    class ApiClient
      include Logging

      # Encapsulates an HTTP request's method, path, and body.
      Request = Struct.new(:method_class, :path, :body, keyword_init: true)

      # Bundles file upload parameters to avoid long parameter lists.
      FileUpload = Data.define(:channel_id, :filename, :content, :content_type)

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

      def post_multipart(path, upload)
        uri = URI.parse(@config.api_url(path))
        req = build_multipart_request(uri, upload)
        response = send_request(uri, req)
        unless response.is_a?(Net::HTTPSuccess)
          log(:error, "Mattermost API POST #{uri.path} multipart failed: " \
                      "#{response.code} #{response.body[0..200]}")
        end
        response
      end

      private

      def execute(request)
        uri = URI.parse(@config.api_url(request.path))
        http_req = build_request(request.method_class, uri, request.body)
        response = send_request(uri, http_req)
        unless response.is_a?(Net::HTTPSuccess)
          log(:error,
              "Mattermost API #{http_req.method} #{uri.path} failed: " \
              "#{response.code} #{response.body[0..200]}")
        end
        response
      end

      def build_request(method_class, uri, body)
        token = @config.bot_token
        req = method_class.new(uri)
        req["Authorization"] = "Bearer #{token}"
        apply_json_body(req, body) if body
        req
      end

      def apply_json_body(req, body)
        req["Content-Type"] = "application/json"
        req.body = JSON.generate(body)
      end

      MAX_RETRIES = 2
      RETRY_DELAY = 1
      RATE_LIMIT_MAX_RETRIES = 3
      private_constant :MAX_RETRIES, :RETRY_DELAY, :RATE_LIMIT_MAX_RETRIES

      def send_request(uri, req)
        attempts = 0
        loop do
          attempts += 1
          response = attempt_request(uri, req, attempts)
          return response unless rate_limited?(response, attempts)

          sleep rate_limit_delay(response, attempts)
        end
      end

      def attempt_request(uri, req, attempts)
        http_start(uri.host, uri.port) { |http| http.request(req) }
      rescue Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, IOError => error
        handle_connection_error(error, attempts)
        retry
      end

      def handle_connection_error(error, attempts)
        raise error if attempts > MAX_RETRIES

        log(:warn, "Mattermost API retry #{attempts}/#{MAX_RETRIES} after #{error.class}: #{error.message}")
        sleep RETRY_DELAY
      end

      def rate_limited?(response, attempts)
        return false unless response.code == "429"
        return false if attempts > RATE_LIMIT_MAX_RETRIES

        log(:warn, "Mattermost API rate limited (attempt #{attempts}/#{RATE_LIMIT_MAX_RETRIES})")
        true
      end

      def rate_limit_delay(response, attempts)
        header_delay = response["X-RateLimit-Reset-After"]&.to_f
        return header_delay if header_delay&.positive?

        RETRY_DELAY * (2**(attempts - 1))
      end

      def http_start(host, port, &)
        Net::HTTP.start(host, port,
                        use_ssl: @config.mattermost_url.start_with?("https"),
                        open_timeout: 10, read_timeout: 15, &)
      end

      # Multipart form-data encoding for file uploads.
      module MultipartEncoding
        BOUNDARY_PREFIX = "EarlUpload"

        private

        def build_multipart_request(uri, upload)
          boundary = "#{BOUNDARY_PREFIX}#{SecureRandom.hex(16)}"
          req = build_request(Net::HTTP::Post, uri, nil)
          req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
          req.body = encode_multipart_body(boundary, upload)
          req
        end

        def encode_multipart_body(boundary, upload)
          [
            field_part(boundary, upload.channel_id),
            file_part(boundary, upload),
            upload.content.b,
            "\r\n--#{boundary}--\r\n"
          ].join.b
        end

        def field_part(boundary, channel_id)
          "--#{boundary}\r\nContent-Disposition: form-data; name=\"channel_id\"\r\n\r\n#{channel_id}\r\n"
        end

        def file_part(boundary, upload)
          "--#{boundary}\r\n" \
            "Content-Disposition: form-data; name=\"files\"; filename=\"#{upload.filename}\"\r\n" \
            "Content-Type: #{upload.content_type}\r\n\r\n"
        end
      end

      include MultipartEncoding
    end
  end
end
