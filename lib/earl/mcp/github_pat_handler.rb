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
        [ tool_definition ]
      end

      def call(name, arguments)
        return unless handles?(name)

        action = arguments["action"]
        actions_list = VALID_ACTIONS.join(", ")
        return text_content("Error: action is required (#{actions_list})") unless action
        return text_content("Error: unknown action '#{action}'. Valid: #{actions_list}") unless VALID_ACTIONS.include?(action)

        send("handle_#{action}", arguments)
      end

      private

      # --- create ---

      def handle_create(arguments)
        request = build_pat_request(arguments)
        return request if error_response?(request)

        execute_create(request)
      end

      def build_pat_request(arguments)
        name = validate_present(arguments["name"], "name is required for create")
        return name if error_response?(name)

        repo = validate_repo(arguments["repo"])
        return repo if error_response?(repo)

        permissions = validate_and_normalize_permissions(arguments["permissions"])
        return permissions if error_response?(permissions)

        expiration = parse_expiration(arguments["expiration_days"])
        return expiration if error_response?(expiration)

        PatRequest.new(name: name, repo: repo, permissions: permissions, expiration: expiration)
      end

      def execute_create(request)
        confirmation = request_create_confirmation(request)
        case confirmation
        when :approved then create_pat(request)
        when :error then text_content("Error: confirmation failed (could not post or connect to Mattermost)")
        else text_content("PAT creation denied by user.")
        end
      end

      # --- validation ---

      def validate_present(value, message)
        return text_content("Error: #{message}") unless value && !value.strip.empty?

        value
      end

      def validate_repo(repo)
        return text_content("Error: repo is required for create (e.g. 'owner/repo')") unless repo && !repo.strip.empty?
        return text_content("Error: repo must be in 'owner/repo' format") unless repo.match?(%r{\A[\w.-]+/[\w.-]+\z})

        repo
      end

      def validate_and_normalize_permissions(permissions)
        return text_content("Error: permissions is required (e.g. {\"contents\": \"write\"})") unless permissions.is_a?(Hash) && !permissions.empty?

        normalized = permissions.each_with_object({}) { |(perm, level), acc| acc[perm.to_s] = level.to_s.downcase }
        error = check_permissions(normalized)
        return text_content("Error: #{error}") if error

        normalized
      end

      def check_permissions(permissions)
        permissions.each do |perm, level|
          return "unknown permission '#{perm}'. Valid: #{Permissions::NAMES.join(', ')}" unless Permissions::NAMES.include?(perm)
          return "invalid access level '#{level}' for '#{perm}'. Valid: #{Permissions::LEVELS.join(', ')}" unless Permissions::LEVELS.include?(level)
        end
        nil
      end

      def parse_expiration(raw)
        return 365 unless raw

        value = raw.to_i
        return text_content("Error: expiration_days must be a positive integer") unless value.positive?

        value
      end

      # --- safari automation ---

      def create_pat(request)
        run_safari_automation(request)
        token = @safari.extract_token
        return text_content("Error: failed to extract token from page. Verify Safari is logged into GitHub and the page loaded correctly.") unless token && !token.empty?

        text_content(format_success(request, token))
      rescue SafariAutomation::Error => error
        reason = error.message
        log(:error, "Safari automation failed during PAT creation: #{reason}")
        text_content("Error: Safari automation failed — #{reason}")
      end

      def run_safari_automation(request)
        @safari.navigate("https://github.com/settings/personal-access-tokens/new")
        sleep 2
        @safari.fill_token_name(request.name)
        @safari.set_expiration(request.expiration)
        @safari.select_repository(request.repo)
        @safari.set_permissions(request.permissions)
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
          response = @api.post("/posts", {
            channel_id: @config.platform_channel_id,
            message: message,
            root_id: @config.platform_thread_id
          })
          return unless http_success?(response)

          JSON.parse(response.body)["id"]
        rescue IOError, JSON::ParserError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
          log(:error, "Failed to post PAT confirmation: #{error.message}")
          nil
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

        def wait_for_confirmation(post_id)
          timeout_sec = @config.permission_timeout_ms / 1000.0
          deadline = Time.now + timeout_sec

          ws = connect_websocket
          return :error unless ws

          poll_confirmation(ws, post_id, deadline)
        ensure
          begin
            ws&.close
          rescue IOError, Errno::ECONNRESET => error
            log(:debug, "Failed to close PAT confirmation WebSocket: #{error.message}")
          end
        end

        def connect_websocket
          ws = WebSocket::Client::Simple.connect(@config.websocket_url)
          token = @config.platform_token
          ws_ref = ws
          ws.on(:open) { ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } })) }
          ws
        rescue IOError, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH => error
          log(:error, "PAT confirmation WebSocket failed: #{error.message}")
          nil
        end

        def poll_confirmation(ws, post_id, deadline)
          reaction_queue = Queue.new
          target_post_id = post_id

          ws.on(:message) do |msg|
            data = msg.data
            next unless data && !data.empty?

            begin
              event = JSON.parse(data)
              if event["event"] == "reaction_added"
                reaction_data = JSON.parse(event.dig("data", "reaction") || "{}")
                reaction_queue.push(reaction_data) if reaction_data["post_id"] == target_post_id
              end
            rescue JSON::ParserError
              log(:debug, "PAT confirmation: skipped unparsable WebSocket message")
            end
          end

          poll_reaction_loop(deadline, reaction_queue)
        end

        def poll_reaction_loop(deadline, reaction_queue)
          loop do
            remaining = deadline - Time.now
            return :denied if remaining <= 0

            reaction = dequeue_reaction(reaction_queue)
            next unless reaction

            result = evaluate_reaction(reaction)
            return result if result
          end
        end

        def dequeue_reaction(reaction_queue)
          reaction_queue.pop(true)
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
        end

        def delete_confirmation_post(post_id)
          @api.delete("/posts/#{post_id}")
        rescue StandardError => error
          log(:warn, "Failed to delete PAT confirmation: #{error.message}")
        end
      end

      include ConfirmationFlow

      # --- helpers ---

      def http_success?(response)
        response.is_a?(Net::HTTPSuccess)
      end

      def error_response?(value)
        value.is_a?(Hash) && value.key?(:content)
      end

      def text_content(text)
        { content: [ { type: "text", text: text } ] }
      end

      def tool_definition
        {
          name: "manage_github_pats",
          description: "Create fine-grained GitHub personal access tokens via Safari automation. " \
                       "Requires Mattermost approval before execution.",
          inputSchema: {
            type: "object",
            properties: {
              action: {
                type: "string",
                enum: VALID_ACTIONS,
                description: "Action to perform"
              },
              name: {
                type: "string",
                description: "Token name (required for create)"
              },
              repo: {
                type: "string",
                description: "Repository in 'owner/repo' format (required for create)"
              },
              permissions: {
                type: "object",
                description: "Permission map, e.g. {\"contents\": \"write\", \"issues\": \"read\"}. " \
                             "Valid permissions: #{Permissions::NAMES.join(', ')}. Levels: read, write.",
                additionalProperties: { type: "string", enum: Permissions::LEVELS }
              },
              expiration_days: {
                type: "integer",
                description: "Token expiration in days (default 365)"
              }
            },
            required: %w[action]
          }
        }
      end
    end
  end
end
