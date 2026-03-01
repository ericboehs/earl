# frozen_string_literal: true

require "securerandom"
require "shellwords"
require "base64"

module Earl
  module Mcp
    # MCP handler for spawning PEARL (Protected EARL) agents — Docker-isolated
    # Claude sessions with scoped credentials. Conforms to the Server handler
    # interface: tool_definitions, handles?, call.
    #
    # Actions:
    #   list_agents — discover available agent profiles
    #   run         — spawn a PEARL agent in the pearl-agents tmux session
    #   status      — check agent output (tmux capture or log file fallback)
    class PearlHandler
      include Logging
      include HandlerBase

      TOOL_NAME = "manage_pearl_agents"
      TOOL_NAMES = [TOOL_NAME].freeze
      VALID_ACTIONS = %w[list_agents run status].freeze
      TMUX_SESSION = "pearl-agents"
      KEEP_ALIVE_SECONDS = 300

      # Bundles run parameters that travel together through the confirmation and creation flow.
      RunRequest = Data.define(:agent, :prompt, :window_name, :log_path, :image_dir, :output_dir) do
        def target
          "#{TMUX_SESSION}:#{window_name}"
        end

        def result_text
          "Spawned PEARL agent `#{agent}` in tmux window `#{target}`.\n" \
            "- **Prompt:** #{prompt}\n" \
            "- **Log:** `#{log_path}`\n" \
            "- **Monitor:** Use `manage_pearl_agents` with action `status` and " \
            "target `#{target}` to check output."
        end

        def pearl_command(pearl_bin)
          base = [pearl_bin, agent, "-p", prompt].map { |arg| Shellwords.shellescape(arg) }.join(" ")
          escaped_log = Shellwords.shellescape(log_path)
          trailer = "echo '--- PEARL agent exited ---' | tee -a #{escaped_log}"
          env_prefix = build_env_prefix
          "#{env_prefix}#{base} 2>&1 | tee #{escaped_log}; #{trailer}; sleep #{KEEP_ALIVE_SECONDS}"
        end

        private

        def build_env_prefix
          vars = []
          vars << "PEARL_IMAGES=#{Shellwords.shellescape(image_dir)}" if image_dir
          vars << "PEARL_OUTPUT=#{Shellwords.shellescape(output_dir)}" if output_dir
          vars.empty? ? "" : "#{vars.join(" ")} "
        end
      end

      def initialize(config:, api_client:, tmux_store:, tmux_adapter: Tmux)
        @config = config
        @api = api_client
        @tmux_store = tmux_store
        @tmux = tmux_adapter
      end

      def tool_definitions
        [tool_definition]
      end

      def call(name, arguments)
        return unless handles?(name)

        error = validate_action(arguments)
        return error if error

        send("handle_#{arguments["action"]}", arguments)
      end

      private

      def validate_action(arguments)
        action = arguments["action"]
        valid_list = VALID_ACTIONS.join(", ")
        return text_content("Error: action is required (#{valid_list})") unless action

        text_content("Error: unknown action '#{action}'. Valid: #{valid_list}") unless VALID_ACTIONS.include?(action)
      end

      def text_content(text)
        { content: [{ type: "text", text: text }] }
      end

      # Discovers available agent profiles from the pearl-agents repo.
      module AgentDiscovery
        private

        def handle_list_agents(_arguments)
          agents_dir = find_agents_dir
          unless agents_dir
            return text_content(
              "Error: pearl-agents repo not found. Set PEARL_BIN or add pearl to PATH."
            )
          end

          agents = discover_agents(agents_dir)
          return text_content("No agent profiles found in #{agents_dir}") if agents.empty?

          lines = agents.map { |agent| format_agent(agent) }
          text_content("**Available PEARL Agents (#{agents.size}):**\n\n#{lines.join("\n")}")
        end

        def find_agents_dir
          repo = pearl_agents_repo
          return unless repo

          dir = File.join(repo, "agents")
          dir if Dir.exist?(dir)
        end

        def pearl_agents_repo
          pearl = resolve_pearl_bin
          return unless pearl

          File.dirname(pearl, 2)
        end

        def discover_agents(agents_dir)
          Dir.children(agents_dir)
             .select { |name| agent_profile?(agents_dir, name) }
             .sort
             .map { |name| build_agent_info(agents_dir, name) }
        end

        def agent_profile?(agents_dir, name)
          name != "base" && File.exist?(File.join(agents_dir, name, "Dockerfile"))
        end

        def build_agent_info(agents_dir, name)
          has_skills = Dir.exist?(File.join(agents_dir, name, "skills"))
          { name: name, has_skills: has_skills }
        end

        def format_agent(agent)
          skills_badge = agent[:has_skills] ? " (skills: yes)" : ""
          "- `#{agent[:name]}`#{skills_badge}"
        end
      end

      # Spawns PEARL agents in the pearl-agents tmux session with Mattermost confirmation.
      module AgentRunner
        INBOUND_IMAGES_HINT = "Images are available at /pearl-images/ inside the container. " \
                              "Use the Read tool to view them."
        OUTPUT_DIR_HINT = "Save any output files (screenshots, images, artifacts) to /pearl-output/. " \
                          "Files placed there are automatically uploaded to the chat."

        private

        def handle_run(arguments)
          error = validate_run_args(arguments)
          return error if error

          request = build_run_request(arguments)
          execute_run(request)
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end

        def validate_run_args(arguments)
          agent = arguments["agent"]
          prompt = arguments["prompt"]
          return text_content("Error: agent is required for run") unless agent && !agent.strip.empty?
          return text_content("Error: prompt is required for run") unless prompt && !prompt.strip.empty?

          validate_pearl_bin || validate_agent_exists(agent)
        end

        def validate_pearl_bin
          text_content("Error: `pearl` CLI not found. Set PEARL_BIN or add pearl to PATH.") unless resolve_pearl_bin
        end

        def validate_agent_exists(agent)
          agents_dir = find_agents_dir
          return unless agents_dir
          return if agent_profile?(agents_dir, agent)

          available = discover_agents(agents_dir).map { |profile| profile[:name] }.join(", ")
          text_content("Error: unknown agent '#{agent}'. Available: #{available}")
        end

        def build_run_request(arguments)
          agent, prompt = arguments.values_at("agent", "prompt")
          window_name = "#{agent}-#{SecureRandom.hex(2)}"
          log_path = File.join(pearl_log_dir, "#{window_name}.log")
          image_dir = write_inbound_images(resolve_image_data(arguments), window_name)
          output_dir = create_output_dir(window_name)
          hints = [INBOUND_IMAGES_HINT].select { image_dir } + [OUTPUT_DIR_HINT]
          full_prompt = [prompt, *hints].join("\n\n")
          RunRequest.new(agent: agent, prompt: full_prompt, window_name: window_name,
                         log_path: log_path, image_dir: image_dir, output_dir: output_dir)
        end

        def create_output_dir(window_name)
          dir = File.join(Earl.config_root, "pearl-output", window_name)
          FileUtils.mkdir_p(dir)
          dir
        end

        def execute_run(request)
          case request_run_confirmation(request)
          when :approved then create_pearl_session(request)
          when :error then text_content("Error: run confirmation failed (could not post or connect to Mattermost)")
          else text_content("Run denied by user.")
          end
        end

        def create_pearl_session(request)
          ensure_tmux_session
          ensure_log_dir
          command = request.pearl_command(resolve_pearl_bin)
          @tmux.create_window(session: TMUX_SESSION, name: request.window_name, command: command)
          persist_session_info(request)
          format_run_result(request)
        end

        def ensure_tmux_session
          @tmux.create_session(name: TMUX_SESSION) unless @tmux.session_exists?(TMUX_SESSION)
        end

        def persist_session_info(request)
          channel_id = @config.platform_channel_id
          thread_id = @config.platform_thread_id
          info = TmuxSessionStore::TmuxSessionInfo.new(
            name: request.target, channel_id: channel_id,
            thread_id: thread_id,
            working_dir: nil, prompt: request.prompt, created_at: Time.now.iso8601
          )
          @tmux_store.save(info)
        end

        def format_run_result(request)
          text_content(request.result_text)
        end

        def ensure_log_dir
          FileUtils.mkdir_p(pearl_log_dir)
        end

        def pearl_log_dir
          File.join(Earl.config_root, "pearl-logs")
        end

        def write_inbound_images(image_data, window_name)
          images = Array(image_data)
          return nil if images.empty?

          dir = File.join(Earl.config_root, "pearl-images", window_name)
          FileUtils.mkdir_p(dir)
          images.each { |img| write_single_image(dir, img) }
          dir
        rescue Errno::ENOENT, Errno::EACCES, Errno::ENOSPC, IOError => error
          log(:error, "PEARL inbound image write failed: #{error.class}: #{error.message}")
          nil
        end

        def write_single_image(dir, img)
          filename = File.basename(img["filename"] || "image.png")
          data = Base64.decode64(img["base64_data"] || "")
          File.binwrite(File.join(dir, filename), data)
        end
      end

      # Checks PEARL agent output by capturing the tmux pane or reading the log file.
      # When output contains image references, uploads them to Mattermost.
      module AgentStatus
        private

        def handle_status(arguments)
          target = arguments["target"]
          return text_content("Error: target is required for status") unless target && !target.strip.empty?

          result = capture_agent_output(target)
          detect_and_upload_images(result, target)
          result
        end

        def capture_agent_output(target)
          output = @tmux.capture_pane(target, lines: 200)
          text_content("**`#{target}` output:**\n```\n#{output}\n```")
        rescue Tmux::NotFound
          read_log_fallback(target)
        rescue Tmux::Error => error
          text_content("Error: #{error.message}")
        end

        SAFE_UPLOAD_DIRS = %w[/tmp /var/tmp].freeze
        IMAGE_EXTENSIONS = "*.{png,jpg,jpeg,gif,webp,svg}"
        private_constant :SAFE_UPLOAD_DIRS, :IMAGE_EXTENSIONS

        def detect_and_upload_images(result, target)
          text_refs = detect_safe_image_refs(result)
          output_refs = scan_output_dir(target)
          refs = (text_refs + output_refs).uniq(&:data)
          return if refs.empty?

          context = upload_context
          file_ids = ImageSupport::Uploader.upload_refs(context, refs)
          ImageSupport::Uploader.post_with_images(context, root_id: @config.platform_thread_id, file_ids: file_ids)
        rescue StandardError => error
          log(:error, "PEARL image upload failed: #{error.class}: #{error.message}")
        end

        def detect_safe_image_refs(result)
          text = result.dig(:content, 0, :text)
          return [] unless text

          refs = ImageSupport::OutputDetector.new.detect_in_text(text)
          refs.select { |ref| safe_upload_path?(ref) }.uniq(&:data)
        end

        def scan_output_dir(target)
          dir = output_dir_for_target(target)
          return [] unless dir && Dir.exist?(dir)

          Dir.glob(File.join(dir, "**", IMAGE_EXTENSIONS)).filter_map { |path| build_output_ref(path) }
        end

        def output_dir_for_target(target)
          name = target.split(":").last
          return unless name && !name.include?("/") && !name.include?("..")

          File.join(Earl.config_root, "pearl-output", name)
        end

        def build_output_ref(path)
          return unless File.file?(path) && File.size(path).positive?

          ImageSupport::OutputDetector::ImageReference.new(
            source: :file_path, data: path,
            media_type: media_type_for_output(path), filename: File.basename(path)
          )
        end

        MEDIA_TYPES = {
          ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg",
          ".gif" => "image/gif", ".webp" => "image/webp", ".svg" => "image/svg+xml"
        }.freeze
        private_constant :MEDIA_TYPES

        def media_type_for_output(path)
          MEDIA_TYPES.fetch(File.extname(path).downcase, "application/octet-stream")
        end

        def safe_upload_path?(ref)
          return true unless ref.source == :file_path

          path = File.expand_path(ref.data)
          config = Earl.config_root
          allowed = SAFE_UPLOAD_DIRS.map { |dir| "#{dir}/" } + [
            "#{File.join(config, "pearl-images")}/",
            "#{File.join(config, "pearl-output")}/"
          ]
          allowed.any? { |prefix| path.start_with?(prefix) }
        end

        def upload_context
          ImageSupport::Uploader::UploadContext.new(
            mattermost: ApiClientAdapter.new(@api), channel_id: @config.platform_channel_id
          )
        end

        LOG_READ_LIMIT = 50_000
        private_constant :LOG_READ_LIMIT

        def read_log_fallback(target)
          log_file = find_log_for_target(target)
          return text_content("Error: pane '#{target}' not found and no log file available") unless log_file

          content = File.read(log_file, LOG_READ_LIMIT)
          text_content("**`#{target}` log** (pane closed):\n```\n#{content}\n```")
        rescue Errno::ENOENT, Errno::EACCES, IOError => error
          text_content("Error: could not read log file #{log_file}: #{error.message}")
        end

        def find_log_for_target(target)
          window_name = target.split(":").last
          return unless window_name

          log_file = File.join(pearl_log_dir, "#{window_name}.log")
          log_file if File.exist?(log_file)
        end
      end

      # Spawn confirmation via Mattermost reactions.
      # Reuses the same pattern as TmuxHandler::SpawnConfirmation.
      module RunConfirmation
        APPROVE_EMOJIS = %w[+1 white_check_mark].freeze
        DENY_EMOJIS = %w[-1].freeze
        REACTION_EMOJIS = (APPROVE_EMOJIS + DENY_EMOJIS).freeze

        private

        def request_run_confirmation(request)
          post_id = post_confirmation_request(request)
          return :error unless post_id

          add_reaction_options(post_id)
          wait_for_confirmation(post_id)
        ensure
          delete_confirmation_post(post_id) if post_id
        end

        def post_confirmation_request(request)
          message = build_confirmation_message(request)
          post_to_channel(message)
        rescue IOError, JSON::ParserError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
          log(:error, "Failed to post PEARL run confirmation: #{error.message}")
          nil
        end

        def build_confirmation_message(request)
          ":whale: **PEARL Agent Request**\n" \
            "Claude wants to run agent `#{request.agent}`\n" \
            "- **Prompt:** #{request.prompt}\n" \
            "- **Window:** `#{request.target}`\n" \
            "React: :+1: approve | :-1: deny"
        end

        def post_to_channel(message)
          response = @api.post("/posts", confirmation_post_body(message))
          return log_post_failure(response) unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)["id"]
        end

        def confirmation_post_body(message)
          { channel_id: @config.platform_channel_id,
            message: message,
            root_id: @config.platform_thread_id }
        end

        def log_post_failure(response)
          log(:warn, "Failed to post PEARL confirmation (HTTP #{response.class})")
          nil
        end

        def add_reaction_options(post_id)
          REACTION_EMOJIS.each do |emoji|
            response = @api.post("/reactions", {
                                   user_id: @config.platform_bot_id,
                                   post_id: post_id,
                                   emoji_name: emoji
                                 })
            log(:warn, "Failed to add reaction #{emoji}") unless response.is_a?(Net::HTTPSuccess)
          end
        rescue IOError, Errno::ECONNREFUSED, Errno::ECONNRESET => error
          log(:error, "Failed to add reaction options: #{error.message}")
        end

        def delete_confirmation_post(post_id)
          @api.delete("/posts/#{post_id}")
        rescue StandardError => error
          log(:warn, "Failed to delete PEARL confirmation: #{error.message}")
        end
      end

      # WebSocket-based polling for run confirmation reactions.
      # NOTE: websocket-client-simple uses instance_exec for on() callbacks,
      # changing self to the WebSocket object. Capture method refs as closures
      # to avoid NoMethodError on our handler methods.
      module RunPolling
        # Bundles WebSocket message handler dependencies for ping/pong and reaction parsing.
        MessageHandlerContext = Data.define(:ws, :post_id, :extractor, :queue) do
          def enqueue(msg)
            reaction_data = extractor.call(msg)
            queue.push(reaction_data) if reaction_data && reaction_data["post_id"] == post_id
          end
        end

        private

        def wait_for_confirmation(post_id)
          deadline = confirmation_deadline

          websocket = connect_websocket
          return :error unless websocket

          queue = build_reaction_queue(websocket, post_id)
          await_reaction(queue, deadline)
        rescue StandardError => error
          log(:error, "PEARL confirmation error: #{error.message}")
          :error
        ensure
          close_websocket(websocket)
        end

        def confirmation_deadline
          Time.now + (@config.permission_timeout_ms / 1000.0)
        end

        def close_websocket(websocket)
          websocket&.close
        rescue IOError, Errno::ECONNRESET
          nil
        end

        def connect_websocket
          websocket = WebSocket::Client::Simple.connect(@config.websocket_url)
          authenticate_websocket(websocket)
          websocket
        rescue IOError, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH => error
          log(:error, "PEARL confirmation WebSocket failed: #{error.message}")
          nil
        end

        def authenticate_websocket(websocket)
          token = @config.platform_token
          ws_ref = websocket
          websocket.on(:open) do
            ws_ref.send(JSON.generate({ seq: 1, action: "authentication_challenge", data: { token: token } }))
          end
        end

        def build_reaction_queue(websocket, target_post_id)
          queue = Queue.new
          ws_ref = websocket
          handler_ctx = build_handler_context(ws_ref, target_post_id, queue)
          enqueue = method(:enqueue_reaction)
          ws_ref.on(:message) do |msg|
            msg.type == :ping ? ws_ref.send(nil, type: :pong) : enqueue.call(handler_ctx, msg)
          end
          queue
        end

        def build_handler_context(ws_ref, target_post_id, queue)
          MessageHandlerContext.new(
            ws: ws_ref, post_id: target_post_id,
            extractor: method(:parse_reaction_event), queue: queue
          )
        end

        def enqueue_reaction(ctx, msg)
          ctx.enqueue(msg)
        rescue StandardError => error
          log(:warn, "PEARL confirmation: error processing WebSocket message: #{error.message}")
        end

        def parse_reaction_event(msg)
          raw = msg.data
          return unless raw && !raw.empty?

          parsed = JSON.parse(raw)
          event_name, nested_data = parsed.values_at("event", "data")
          return unless event_name == "reaction_added"

          JSON.parse(nested_data&.dig("reaction") || "{}")
        rescue JSON::ParserError
          log(:debug, "PEARL confirmation: skipped unparsable WebSocket message")
          nil
        end

        def await_reaction(queue, deadline)
          loop do
            return :denied if (deadline - Time.now) <= 0

            reaction = dequeue_reaction(queue)
            next unless reaction

            result = classify_reaction(reaction)
            return result if result
          end
        end

        def dequeue_reaction(queue)
          queue.pop(true)
        rescue ThreadError
          sleep 0.5
          nil
        end
      end

      # Reaction classification and user validation for run confirmations.
      module ReactionClassification
        private

        def classify_reaction(reaction)
          user_id = reaction["user_id"]
          return if user_id == @config.platform_bot_id
          return unless allowed_reactor?(user_id)

          emoji = reaction["emoji_name"]
          return :approved if RunConfirmation::APPROVE_EMOJIS.include?(emoji)

          :denied if RunConfirmation::DENY_EMOJIS.include?(emoji)
        end

        def allowed_reactor?(user_id)
          allowed = @config.allowed_users
          return true if allowed.empty?

          response = @api.get("/users/#{user_id}")
          return false unless response.is_a?(Net::HTTPSuccess)

          user = JSON.parse(response.body)
          allowed.include?(user["username"])
        end
      end

      # Tool definition schema.
      module ToolDefinitionBuilder
        private

        def tool_definition
          {
            name: TOOL_NAME,
            description: pearl_tool_description,
            inputSchema: pearl_input_schema
          }
        end

        def pearl_tool_description
          "Manage PEARL (Protected EARL) Docker-isolated Claude agents. " \
            "List available agent profiles, spawn an agent, or check agent output."
        end

        def pearl_input_schema
          { type: "object", properties: pearl_properties, required: %w[action] }
        end

        def pearl_properties
          {
            action: action_property,
            agent: { type: "string", description: "Agent profile name (e.g., 'code'). Required for run." },
            prompt: { type: "string", description: "Prompt for the PEARL agent session. Required for run." },
            target: target_property,
            image_data: image_data_property,
            file_ids: file_ids_property
          }
        end

        def target_property
          { type: "string", description: "Tmux target (e.g., 'pearl-agents:code-ab12'). Required for status." }
        end

        def action_property
          { type: "string", enum: VALID_ACTIONS, description: "Action to perform" }
        end

        def image_data_property
          {
            type: "array",
            description: "Optional images to pass to the agent. Each item has filename, base64_data, media_type.",
            items: image_data_item_schema
          }
        end

        def image_data_item_schema
          {
            type: "object",
            properties: {
              filename: { type: "string", description: "Image filename (e.g., 'screenshot.png')" },
              base64_data: { type: "string", description: "Base64-encoded image content" },
              media_type: { type: "string", description: "MIME type (e.g., 'image/png')" }
            },
            required: %w[base64_data]
          }
        end

        def file_ids_property
          {
            type: "array",
            description: "Mattermost file IDs to download and pass as images to the agent. " \
                         "Alternative to image_data — the handler downloads files automatically.",
            items: { type: "string" }
          }
        end
      end

      # Downloads Mattermost files by ID, converting them to the image_data format
      # used by write_inbound_images.
      module MattermostDownload
        private

        def resolve_image_data(arguments)
          image_data, file_ids = arguments.values_at("image_data", "file_ids")
          explicit = Array(image_data)
          return explicit unless explicit.empty?

          download_mattermost_files(Array(file_ids))
        end

        def download_mattermost_files(file_ids)
          file_ids.filter_map { |fid| download_single_file(fid) }
        end

        def download_single_file(file_id)
          info_response = @api.get("/files/#{file_id}/info")
          return unless info_response.is_a?(Net::HTTPSuccess)

          data_response = @api.get("/files/#{file_id}")
          return unless data_response.is_a?(Net::HTTPSuccess)

          info = JSON.parse(info_response.body)
          build_file_data(info, data_response.body)
        rescue JSON::ParserError
          nil
        end

        def build_file_data(info, body)
          {
            "filename" => info["name"] || "image.png",
            "base64_data" => Base64.strict_encode64(body),
            "media_type" => info["mime_type"] || "image/png"
          }
        end
      end

      # Resolves the pearl CLI binary path.
      module PearlBinResolver
        private

        def resolve_pearl_bin
          ENV.fetch("PEARL_BIN", nil) || find_pearl_in_path
        end

        def find_pearl_in_path
          output, status = Open3.capture2e("which", "pearl")
          status.success? ? output.strip : nil
        rescue Errno::ENOENT
          nil
        end
      end

      # Thin adapter wrapping ApiClient with Mattermost-compatible upload/post
      # methods, so Uploader can work without a full Mattermost instance.
      class ApiClientAdapter
        def initialize(api)
          @api = api
        end

        def upload_file(upload)
          parse_response(@api.post_multipart("/files", upload))
        end

        def create_post_with_files(file_post)
          parse_response(@api.post("/posts", file_post.to_h))
        end

        private

        def parse_response(response)
          logger = Earl.logger
          unless response.is_a?(Net::HTTPSuccess)
            logger.warn("PearlHandler: API request failed (HTTP #{response.code})")
            return {}
          end

          JSON.parse(response.body)
        rescue JSON::ParserError => error
          logger.warn("PearlHandler: JSON parse failed: #{error.message}")
          {}
        end
      end

      include AgentDiscovery
      include AgentRunner
      include AgentStatus
      include RunConfirmation
      include RunPolling
      include ReactionClassification
      include ToolDefinitionBuilder
      include MattermostDownload
      include PearlBinResolver
    end
  end
end
