# frozen_string_literal: true

module Earl
  module Mcp
    # MCP handler exposing a manage_github_pats tool to create fine-grained
    # GitHub personal access tokens via Safari automation (osascript).
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class GithubPatHandler
      include Logging
      include HandlerBase

      TOOL_NAMES = %w[manage_github_pats].freeze
      VALID_ACTIONS = %w[create].freeze

      # Bundles PAT creation parameters that travel together through the flow.
      PatRequest = Data.define(:name, :repo, :permissions, :expiration)

      # Reaction emoji sets for the confirmation flow.
      module Reactions
        APPROVE = %w[+1 white_check_mark].freeze
        DENY = %w[-1].freeze
        ALL = (APPROVE + DENY).freeze
      end

      # Valid permission names and access levels for fine-grained PATs.
      module Permissions
        NAMES = %w[
          actions administration contents issues pull_requests
          metadata packages workflows environments
        ].freeze
        LEVELS = %w[read write].freeze
      end

      def initialize(config:, api_client:, safari_adapter: SafariAutomation)
        @config = config
        @api = api_client
        @safari = safari_adapter
      end

      def tool_definitions
        [tool_definition]
      end

      def call(name, arguments)
        return unless handles?(name)

        action = arguments["action"]
        actions_list = VALID_ACTIONS.join(", ")
        return text_content("Error: action is required (#{actions_list})") unless action
        unless VALID_ACTIONS.include?(action)
          return text_content("Error: unknown action '#{action}'. Valid: #{actions_list}")
        end

        send("handle_#{action}", arguments)
      end

      private

      # --- helpers ---

      def http_success?(response)
        response.is_a?(Net::HTTPSuccess)
      end

      def error_response?(value)
        value.is_a?(Hash) && value.key?(:content)
      end

      def text_content(text)
        { content: [{ type: "text", text: text }] }
      end

      # Request building and validation.
      module RequestValidation
        private

        def handle_create(arguments)
          request = build_pat_request(arguments)
          return request if error_response?(request)

          execute_create(request)
        end

        def build_pat_request(arguments)
          name_error = validate_name(arguments["name"])
          return name_error if name_error

          repo_error = validate_repo(arguments["repo"])
          return repo_error if repo_error

          build_validated_request(arguments)
        end

        def build_validated_request(arguments)
          permissions = validate_and_normalize_permissions(arguments["permissions"])
          return permissions if error_response?(permissions)

          expiration = parse_expiration(arguments["expiration_days"])
          return expiration if error_response?(expiration)

          PatRequest.new(name: arguments["name"], repo: arguments["repo"],
                         permissions: permissions, expiration: expiration)
        end

        def validate_name(name)
          return nil if valid_string?(name)

          text_content("Error: name is required for create")
        end

        def validate_repo(repo)
          return text_content("Error: repo is required for create (e.g. 'owner/repo')") unless valid_string?(repo)
          return nil if repo.match?(%r{\A[\w.-]+/[\w.-]+\z})

          text_content("Error: repo must be in 'owner/repo' format")
        end

        def valid_string?(value)
          value.is_a?(String) && !value.strip.empty?
        end

        def validate_and_normalize_permissions(permissions)
          unless permissions.is_a?(Hash) && !permissions.empty?
            return text_content("Error: permissions is required (e.g. {\"contents\": \"write\"})")
          end

          normalized = permissions.each_with_object({}) { |(perm, level), acc| acc[perm.to_s] = level.to_s.downcase }
          error = check_permissions(normalized)
          return text_content("Error: #{error}") if error

          normalized
        end

        def check_permissions(permissions)
          permissions.each do |perm, level|
            unless Permissions::NAMES.include?(perm)
              return "unknown permission '#{perm}'. Valid: #{Permissions::NAMES.join(", ")}"
            end
            unless Permissions::LEVELS.include?(level)
              return "invalid access level '#{level}' for '#{perm}'. Valid: #{Permissions::LEVELS.join(", ")}"
            end
          end
          nil
        end

        def parse_expiration(raw)
          return 365 unless raw

          value = raw.to_i
          return text_content("Error: expiration_days must be a positive integer") unless value.positive?

          value
        end
      end

      include RequestValidation

      # Safari automation execution.
      module SafariExecution
        private

        def execute_create(request)
          confirmation = request_create_confirmation(request)
          case confirmation
          when :approved then create_pat(request)
          when :error then text_content("Error: confirmation failed (could not post or connect to Mattermost)")
          else text_content("PAT creation denied by user.")
          end
        end

        def create_pat(request)
          run_safari_automation(request)
          token = @safari.extract_token
          return token_extraction_error unless token && !token.empty?

          text_content(format_success(request, token))
        rescue SafariAutomation::Error => error
          error_msg = error.message
          log(:error, "Safari automation failed during PAT creation: #{error_msg}")
          text_content("Error: Safari automation failed — #{error_msg}")
        end

        def token_extraction_error
          text_content(
            "Error: failed to extract token from page. " \
            "Verify Safari is logged into GitHub and the page loaded correctly."
          )
        end

        def run_safari_automation(request)
          @safari.navigate("https://github.com/settings/personal-access-tokens/new")
          sleep 2
          @safari.fill_token_name(request.name)
          @safari.apply_expiration(request.expiration)
          @safari.select_repository(request.repo)
          @safari.apply_permissions(request.permissions)
          @safari.click_generate
          @safari.confirm_generation
        end

        def format_success(request, token)
          perms = request.permissions.map { |perm, level| "#{perm}:#{level}" }.join(", ")
          "PAT created successfully.\n" \
            "- **Name:** #{request.name}\n" \
            "- **Repo:** #{request.repo}\n" \
            "- **Permissions:** #{perms}\n" \
            "- **Expires:** #{request.expiration} days\n" \
            "- **Token:** `#{token}`"
        end
      end

      include SafariExecution

      # WebSocket-based reaction polling for PAT confirmation.
      module ConfirmationFlow
        private

        def request_create_confirmation(request)
          post_id = post_confirmation_request(request)
          return :error unless post_id

          add_reaction_options(post_id)
          wait_for_confirmation(post_id)
        ensure
          delete_confirmation_post(post_id) if post_id
        end

        def post_confirmation_request(request)
          message = format_confirmation_message(request)
          response = post_confirmation_to_channel(message)
          return log_confirmation_failure(response) unless http_success?(response)

          JSON.parse(response.body)["id"]
        rescue IOError, JSON::ParserError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
          log(:error, "Failed to post PAT confirmation: #{error.message}")
          nil
        end

        def post_confirmation_to_channel(message)
          @api.post("/posts", {
                      channel_id: @config.platform_channel_id,
                      message: message,
                      root_id: @config.platform_thread_id
                    })
        end

        def log_confirmation_failure(response)
          status = extract_http_status(response)
          log(:error, "PAT confirmation post failed (HTTP #{status})")
          nil
        end

        def extract_http_status(response)
          response.is_a?(Net::HTTPResponse) ? response.code : "unknown"
        end

        def format_confirmation_message(request)
          perms_list = request.permissions.map { |perm, level| "`#{perm}`: #{level}" }.join(", ")
          ":key: **GitHub PAT Request**\n" \
            "Claude wants to create a fine-grained PAT\n" \
            "- **Name:** #{request.name}\n" \
            "- **Repo:** #{request.repo}\n" \
            "- **Permissions:** #{perms_list}\n" \
            "- **Expiration:** #{request.expiration} days\n" \
            "React: :+1: approve | :-1: deny"
        end

        def add_reaction_options(post_id)
          Reactions::ALL.each do |emoji|
            response = @api.post("/reactions", {
                                   user_id: @config.platform_bot_id,
                                   post_id: post_id,
                                   emoji_name: emoji
                                 })
            log(:warn, "Failed to add reaction #{emoji} to post #{post_id}") unless http_success?(response)
          end
        rescue IOError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
          log(:error, "Failed to add reaction options to post #{post_id}: #{error.message}")
        end
      end

      include ConfirmationFlow

      # WebSocket polling for PAT confirmation reactions.
      module ConfirmationPolling
        private

        def wait_for_confirmation(post_id)
          deadline = Time.now + (@config.permission_timeout_ms / 1000.0)
          websocket = connect_websocket
          return :error unless websocket

          poll_confirmation(websocket, post_id, deadline)
        ensure
          close_websocket(websocket)
        end

        def close_websocket(websocket)
          websocket&.close
        rescue IOError, SocketError, Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE => error
          log(:debug, "Failed to close PAT confirmation WebSocket: #{error.message}")
        end

        def connect_websocket
          websocket = WebSocket::Client::Simple.connect(@config.websocket_url)
          token = @config.platform_token
          ws_ref = websocket
          websocket.on(:open) do
            ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } }))
          end
          websocket
        rescue IOError, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH => error
          log(:error, "PAT confirmation WebSocket failed: #{error.message}")
          nil
        end

        def poll_confirmation(websocket, post_id, deadline)
          queue = setup_reaction_listener(websocket, post_id)
          poll_reaction_loop(deadline, queue)
        end

        def setup_reaction_listener(websocket, post_id)
          queue = Queue.new
          websocket.on(:message) do |msg|
            reaction = extract_reaction(msg)
            queue.push(reaction) if reaction_matches?(reaction, post_id)
          end
          queue
        end

        def reaction_matches?(reaction, post_id)
          reaction && reaction["post_id"] == post_id
        end

        def extract_reaction(msg)
          raw = msg.data
          return unless raw && !raw.empty?

          parsed = JSON.parse(raw)
          event_name, nested_data = parsed.values_at("event", "data")
          return unless event_name == "reaction_added"

          JSON.parse(nested_data&.dig("reaction") || "{}")
        rescue JSON::ParserError
          log(:debug, "PAT confirmation: skipped unparsable WebSocket message")
          nil
        end

        def poll_reaction_loop(deadline, queue)
          loop do
            return :denied if (deadline - Time.now) <= 0

            reaction = dequeue_reaction(queue)
            next unless reaction

            result = evaluate_reaction(reaction)
            return result if result
          end
        end

        def dequeue_reaction(queue)
          queue.pop(true)
        rescue ThreadError
          sleep 0.5
          nil
        end

        def evaluate_reaction(reaction)
          user_id = reaction["user_id"]
          emoji = reaction["emoji_name"]
          return nil if user_id == @config.platform_bot_id
          return nil unless allowed_reactor?(user_id)

          return :approved if Reactions::APPROVE.include?(emoji)

          :denied if Reactions::DENY.include?(emoji)
        end

        def allowed_reactor?(user_id)
          allowed = @config.allowed_users
          return true if allowed.empty?

          response = @api.get("/users/#{user_id}")
          return false unless http_success?(response)

          user = JSON.parse(response.body)
          allowed.include?(user["username"])
        rescue IOError, JSON::ParserError, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
          log(:warn, "Failed to verify reactor #{user_id}: #{error.message}")
          false
        end

        def delete_confirmation_post(post_id)
          @api.delete("/posts/#{post_id}")
        rescue IOError, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EPIPE => error
          log(:warn, "Failed to delete PAT confirmation post #{post_id}: #{error.message}")
        end
      end

      include ConfirmationPolling

      # Tool definition builder.
      module ToolDefinitionBuilder
        private

        def tool_definition
          {
            name: "manage_github_pats",
            description: pat_tool_description,
            inputSchema: pat_input_schema
          }
        end

        def pat_tool_description
          "Create fine-grained GitHub personal access tokens via Safari automation. " \
            "Requires Mattermost approval before execution."
        end

        def pat_input_schema
          {
            type: "object",
            properties: pat_properties,
            required: %w[action]
          }
        end

        def pat_properties
          {
            action: { type: "string", enum: VALID_ACTIONS, description: "Action to perform" },
            name: { type: "string", description: "Token name (required for create)" },
            repo: { type: "string", description: "Repository in 'owner/repo' format (required for create)" },
            permissions: pat_permissions_property,
            expiration_days: { type: "integer", description: "Token expiration in days (default 365)" }
          }
        end

        def pat_permissions_property
          {
            type: "object",
            description: "Permission map, e.g. {\"contents\": \"write\", \"issues\": \"read\"}. " \
                         "Valid permissions: #{Permissions::NAMES.join(", ")}. Levels: read, write.",
            additionalProperties: { type: "string", enum: Permissions::LEVELS }
          }
        end
      end

      include ToolDefinitionBuilder
    end
  end
end
