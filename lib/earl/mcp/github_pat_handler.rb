# frozen_string_literal: true

module Earl
  module Mcp
    # MCP handler exposing a manage_github_pats tool to create fine-grained
    # GitHub personal access tokens via Safari automation (osascript).
    # Conforms to the Server handler interface: tool_definitions, handles?, call.
    class GithubPatHandler
      include Logging

      TOOL_NAME = "manage_github_pats"
      VALID_ACTIONS = %w[create].freeze

      APPROVE_EMOJIS = %w[+1 white_check_mark].freeze
      DENY_EMOJIS = %w[-1].freeze
      REACTION_EMOJIS = (APPROVE_EMOJIS + DENY_EMOJIS).freeze

      VALID_PERMISSIONS = %w[
        actions administration contents issues pull_requests
        metadata packages workflows environments
      ].freeze
      VALID_ACCESS_LEVELS = %w[read write].freeze

      def initialize(config:, api_client:, safari_adapter: SafariAutomation)
        @config = config
        @api = api_client
        @safari = safari_adapter
      end

      def tool_definitions
        [ tool_definition ]
      end

      def handles?(name)
        name == TOOL_NAME
      end

      def call(name, arguments)
        return unless name == TOOL_NAME

        action = arguments["action"]
        return text_content("Error: action is required (#{VALID_ACTIONS.join(', ')})") unless action
        return text_content("Error: unknown action '#{action}'. Valid: #{VALID_ACTIONS.join(', ')}") unless VALID_ACTIONS.include?(action)

        send("handle_#{action}", arguments)
      end

      private

      # --- create ---

      def handle_create(arguments)
        name = arguments["name"]
        return text_content("Error: name is required for create") unless name && !name.strip.empty?

        repo = arguments["repo"]
        return text_content("Error: repo is required for create (e.g. 'owner/repo')") unless repo && !repo.strip.empty?
        # Allows alphanumerics, underscores, dots, and hyphens in owner/repo
        return text_content("Error: repo must be in 'owner/repo' format") unless repo.match?(%r{\A[\w.-]+/[\w.-]+\z})

        permissions = arguments["permissions"]
        return text_content("Error: permissions is required (e.g. {\"contents\": \"write\"})") unless permissions.is_a?(Hash) && !permissions.empty?

        # Normalize permission keys and access levels to lowercase strings
        normalized_permissions = permissions.each_with_object({}) do |(perm, level), acc|
          acc[perm.to_s] = level.to_s.downcase
        end

        error = validate_permissions(normalized_permissions)
        return text_content("Error: #{error}") if error

        expiration = validate_expiration(arguments["expiration_days"])
        return expiration if expiration.is_a?(Hash)

        confirmation = request_create_confirmation(
          name: name, repo: repo, permissions: normalized_permissions, expiration: expiration
        )
        case confirmation
        when :approved
          create_pat(name: name, repo: repo, permissions: normalized_permissions, expiration: expiration)
        when :error
          text_content("Error: confirmation failed (could not post or connect to Mattermost)")
        else
          text_content("PAT creation denied by user.")
        end
      end

      def validate_permissions(permissions)
        permissions.each do |perm, level|
          return "unknown permission '#{perm}'. Valid: #{VALID_PERMISSIONS.join(', ')}" unless VALID_PERMISSIONS.include?(perm)
          return "invalid access level '#{level}' for '#{perm}'. Valid: #{VALID_ACCESS_LEVELS.join(', ')}" unless VALID_ACCESS_LEVELS.include?(level)
        end
        nil
      end

      def validate_expiration(raw)
        return 365 if raw.nil?

        value = raw.to_i
        return text_content("Error: expiration_days must be a positive integer") unless value.positive?

        value
      end

      def create_pat(name:, repo:, permissions:, expiration:)
        @safari.navigate("https://github.com/settings/personal-access-tokens/new")
        sleep 2

        @safari.fill_token_name(name)
        @safari.set_expiration(expiration)
        @safari.select_repository(repo)
        @safari.set_permissions(permissions)
        @safari.click_generate
        @safari.confirm_generation

        token = @safari.extract_token
        return text_content("Error: failed to extract token from page. Verify Safari is logged into GitHub and the page loaded correctly.") unless token && !token.empty?

        text_content(
          "PAT created successfully.\n" \
          "- **Name:** #{name}\n" \
          "- **Repo:** #{repo}\n" \
          "- **Permissions:** #{permissions.map { |k, v| "#{k}:#{v}" }.join(', ')}\n" \
          "- **Expires:** #{expiration} days\n" \
          "- **Token:** `#{token}`"
        )
      rescue SafariAutomation::Error => error
        log(:error, "Safari automation failed during PAT creation: #{error.message}")
        text_content("Error: Safari automation failed — #{error.message}")
      end

      # --- confirmation ---

      def request_create_confirmation(name:, repo:, permissions:, expiration:)
        post_id = post_confirmation_request(name, repo, permissions, expiration)
        return :error unless post_id

        add_reaction_options(post_id)
        wait_for_confirmation(post_id)
      ensure
        delete_confirmation_post(post_id) if post_id
      end

      def post_confirmation_request(name, repo, permissions, expiration)
        perms_list = permissions.map { |k, v| "`#{k}`: #{v}" }.join(", ")
        message = ":key: **GitHub PAT Request**\n" \
                  "Claude wants to create a fine-grained PAT\n" \
                  "- **Name:** #{name}\n" \
                  "- **Repo:** #{repo}\n" \
                  "- **Permissions:** #{perms_list}\n" \
                  "- **Expiration:** #{expiration} days\n" \
                  "React: :+1: approve | :-1: deny"

        response = @api.post("/posts", {
          channel_id: @config.platform_channel_id,
          message: message,
          root_id: @config.platform_thread_id
        })

        return unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)["id"]
      rescue IOError, JSON::ParserError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
        log(:error, "Failed to post PAT confirmation: #{error.message}")
        nil
      end

      def add_reaction_options(post_id)
        REACTION_EMOJIS.each do |emoji|
          response = @api.post("/reactions", {
            user_id: @config.platform_bot_id,
            post_id: post_id,
            emoji_name: emoji
          })
          log(:warn, "Failed to add reaction #{emoji} to post #{post_id}") unless response.is_a?(Net::HTTPSuccess)
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
        ws_ref = ws # Capture for closure (avoid referencing ws before assignment completes)
        ws.on(:open) { ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } })) }
        ws
      rescue IOError, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH => error
        log(:error, "PAT confirmation WebSocket failed: #{error.message}")
        nil
      end

      def poll_confirmation(ws, post_id, deadline)
        reaction_queue = Queue.new

        ws.on(:message) do |msg|
          next unless msg.data && !msg.data.empty?

          begin
            event = JSON.parse(msg.data)
            if event["event"] == "reaction_added"
              reaction_data = JSON.parse(event.dig("data", "reaction") || "{}")
              reaction_queue.push(reaction_data) if reaction_data["post_id"] == post_id
            end
          rescue JSON::ParserError
            log(:debug, "PAT confirmation: skipped unparsable WebSocket message")
          end
        end

        loop do
          remaining = deadline - Time.now
          return :denied if remaining <= 0

          reaction = begin
            reaction_queue.pop(true)
          rescue ThreadError
            sleep 0.5
            nil
          end

          next unless reaction
          next if reaction["user_id"] == @config.platform_bot_id
          next unless allowed_reactor?(reaction["user_id"])

          return :approved if APPROVE_EMOJIS.include?(reaction["emoji_name"])
          return :denied if DENY_EMOJIS.include?(reaction["emoji_name"])
        end
      end

      def allowed_reactor?(user_id)
        return true if @config.allowed_users.empty?

        response = @api.get("/users/#{user_id}")
        return false unless response.is_a?(Net::HTTPSuccess)

        user = JSON.parse(response.body)
        @config.allowed_users.include?(user["username"])
      end

      def delete_confirmation_post(post_id)
        @api.delete("/posts/#{post_id}")
      rescue StandardError => error
        log(:warn, "Failed to delete PAT confirmation: #{error.message}")
      end

      # --- helpers ---

      def text_content(text)
        { content: [ { type: "text", text: text } ] }
      end

      def tool_definition
        {
          name: TOOL_NAME,
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
                             "Valid permissions: #{VALID_PERMISSIONS.join(', ')}. Levels: read, write.",
                additionalProperties: { type: "string", enum: VALID_ACCESS_LEVELS }
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
