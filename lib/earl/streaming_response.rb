# frozen_string_literal: true

module Earl
  # Manages the lifecycle of a single streamed response to Mattermost,
  # including post creation, debounced updates, and typing indicators.
  class StreamingResponse
    include Logging
    DEBOUNCE_MS = 300
    TOOL_ICONS = {
      "Bash" => "🔧", "Read" => "📖", "WebFetch" => "🌐", "WebSearch" => "🌐",
      "Edit" => "✏️", "Write" => "📝", "Glob" => "🔍", "Grep" => "🔍"
    }.freeze
    TOOL_PREFIXES = TOOL_ICONS.values.uniq.concat([ "⚙️" ]).freeze

    # Holds the Mattermost thread and channel context for posting.
    Context = Struct.new(:thread_id, :mattermost, :channel_id, keyword_init: true)
    # Tracks the reply post lifecycle: ID, failure state, text, and debounce timing.
    PostState = Struct.new(:reply_post_id, :create_failed, :full_text, :last_update_at, :debounce_timer, keyword_init: true)

    def initialize(thread_id:, mattermost:, channel_id:)
      @context = Context.new(thread_id: thread_id, mattermost: mattermost, channel_id: channel_id)
      @post_state = PostState.new(create_failed: false, full_text: "", last_update_at: Time.now)
      @segments = []
      @typing_thread = nil
      @mutex = Mutex.new
    end

    def channel_id
      @context.channel_id
    end

    def start_typing
      @typing_thread = Thread.new { typing_loop }
    end

    def on_text(text)
      @mutex.synchronize { handle_text(text) }
    rescue StandardError => error
      log(:error, "Streaming error (thread #{short_id}): #{error.class}: #{error.message}")
      log(:error, error.backtrace.first(5).join("\n"))
    end

    def on_tool_use(tool_use)
      @mutex.synchronize { handle_tool_use_display(tool_use) }
    rescue StandardError => error
      log(:error, "Tool use display error (thread #{short_id}): #{error.class}: #{error.message}")
      log(:error, error.backtrace.first(5).join("\n"))
    end

    def on_complete(stats_line: nil)
      @mutex.synchronize { finalize(stats_line) }
    rescue StandardError => error
      log(:error, "Completion error (thread #{short_id}): #{error.class}: #{error.message}")
      log(:error, error.backtrace.first(5).join("\n"))
    end

    private

    def typing_loop
      loop do
        send_typing_indicator
        sleep 3
      end
    rescue StandardError => error
      log(:warn, "Typing error (thread #{short_id}): #{error.class}: #{error.message}")
    end

    def send_typing_indicator
      @context.mattermost.send_typing(channel_id: @context.channel_id, parent_id: @context.thread_id)
    end

    def handle_text(text)
      @segments << text
      @post_state.full_text = @segments.join("\n\n")
      stop_typing

      return if @post_state.create_failed
      return create_initial_post(@post_state.full_text) unless @post_state.reply_post_id

      schedule_update
    end

    def create_initial_post(text)
      result = @context.mattermost.create_post(channel_id: @context.channel_id, message: text, root_id: @context.thread_id)
      post_id = result["id"]
      return handle_create_failure unless post_id

      @post_state.reply_post_id = post_id
      @post_state.last_update_at = Time.now
    end

    def handle_create_failure
      @post_state.create_failed = true
      log(:error, "Failed to create post for thread #{short_id} — subsequent text will be dropped")
    end

    def schedule_update
      elapsed_ms = (Time.now - @post_state.last_update_at) * 1000

      if elapsed_ms >= DEBOUNCE_MS
        update_post
      else
        start_debounce_timer
      end
    end

    def start_debounce_timer
      return if @post_state.debounce_timer

      @post_state.debounce_timer = Thread.new do
        sleep DEBOUNCE_MS / 1000.0
        @mutex.synchronize { update_post }
      end
    end

    def update_post
      @post_state.debounce_timer = nil
      @context.mattermost.update_post(post_id: @post_state.reply_post_id, message: @post_state.full_text)
      @post_state.last_update_at = Time.now
    end

    def finalize(stats_line)
      stop_typing
      return if @post_state.full_text.empty? && !@post_state.reply_post_id

      final_text = build_final_text(stats_line)

      if only_text_segments?
        # Simple response (no tool use) — edit existing post with stats footer
        @post_state.full_text = final_text
        update_post if @post_state.reply_post_id
      else
        # Multi-segment response — pull final answer out into a new post
        remove_last_text_from_streamed_post
        create_notification_post(final_text)
      end
    end

    def only_text_segments?
      @segments.none? { |segment| tool_segment?(segment) }
    end

    def build_final_text(stats_line)
      last_text = @segments.reverse.find { |segment| !tool_segment?(segment) }
      text = last_text || @post_state.full_text
      stats_line ? "#{text}\n\n---\n#{stats_line}" : text
    end

    def remove_last_text_from_streamed_post
      return unless @post_state.reply_post_id

      last_text_index = @segments.rindex { |segment| !tool_segment?(segment) }
      return unless last_text_index

      @segments.delete_at(last_text_index)
      @post_state.full_text = @segments.join("\n\n")
      update_post unless @post_state.full_text.empty?
    end

    def create_notification_post(text)
      @context.mattermost.create_post(
        channel_id: @context.channel_id, message: text, root_id: @context.thread_id
      )
    end

    def stop_typing
      @typing_thread&.kill
      @typing_thread = nil
    end

    def handle_tool_use_display(tool_use)
      return if tool_use[:name] == "AskUserQuestion"

      @segments << format_tool_use(tool_use)
      @post_state.full_text = @segments.join("\n\n")
      stop_typing

      return if @post_state.create_failed
      return create_initial_post(@post_state.full_text) unless @post_state.reply_post_id

      schedule_update
    end

    def format_tool_use(tool_use)
      name = tool_use[:name]
      icon = TOOL_ICONS.fetch(name, "⚙️")
      detail = extract_tool_detail(tool_use)

      if detail
        "#{icon} `#{name}`\n```\n#{detail}\n```"
      else
        "#{icon} `#{name}`"
      end
    end

    # :reek:ControlParameter
    def extract_tool_detail(tool_use)
      input = tool_use[:input] || {}
      case tool_use[:name]
      when "Bash" then input["command"]
      when "Read", "Edit", "Write" then input["file_path"]
      when "WebFetch" then input["url"]
      when "WebSearch" then input["query"]
      when "Grep", "Glob" then input["pattern"]
      else
        compact = input.compact
        compact.empty? ? nil : JSON.generate(compact)
      end
    end

    def tool_segment?(segment)
      TOOL_PREFIXES.any? { |prefix| segment.start_with?(prefix) }
    end

    def short_id
      @context.thread_id[0..7]
    end
  end
end
