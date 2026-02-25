# frozen_string_literal: true

module Earl
  # Manages the lifecycle of a single streamed response to Mattermost,
  # including post creation, debounced updates, and typing indicators.
  class StreamingResponse
    include Logging
    include ToolInputFormatter

    DEBOUNCE_MS = 300
    TOOL_PREFIXES = ToolInputFormatter::TOOL_ICONS.values.uniq.push("\u2699\uFE0F").freeze

    # Holds the Mattermost thread and channel context for posting.
    Context = Struct.new(:thread_id, :mattermost, :channel_id, keyword_init: true)
    # Tracks the reply post lifecycle: ID, failure state, text, debounce timing, and typing thread.
    PostState = Struct.new(:reply_post_id, :create_failed, :full_text, :last_update_at,
                           :debounce_timer, :typing_thread, keyword_init: true)

    def initialize(thread_id:, mattermost:, channel_id:)
      @context = Context.new(thread_id: thread_id, mattermost: mattermost, channel_id: channel_id)
      @post_state = PostState.new(create_failed: false, full_text: "", last_update_at: Time.now)
      @segments = []
      @mutex = Mutex.new
    end

    def channel_id
      @context.channel_id
    end

    def start_typing
      @post_state.typing_thread = Thread.new { typing_loop }
    end

    def on_text(text)
      @mutex.synchronize { handle_text(text) }
    rescue StandardError => error
      log(:error, "Streaming error (thread #{short_id}): #{error.class}: #{error.message}")
      log(:error, error.backtrace&.first(5)&.join("\n"))
    end

    def on_tool_use(tool_use)
      @mutex.synchronize { handle_tool_use_display(tool_use) }
    rescue StandardError => error
      log(:error, "Tool use display error (thread #{short_id}): #{error.class}: #{error.message}")
      log(:error, error.backtrace&.first(5)&.join("\n"))
    end

    def on_complete(**)
      @mutex.synchronize { finalize }
    rescue StandardError => error
      log(:error, "Completion error (thread #{short_id}): #{error.class}: #{error.message}")
      log(:error, error.backtrace&.first(5)&.join("\n"))
    end

    def stop_typing
      @post_state.typing_thread&.kill
      @post_state.typing_thread = nil
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
      return create_initial_post(@post_state.full_text) unless posted?

      schedule_update
    end

    def posted?
      !!@post_state.reply_post_id
    end

    # Post creation and update lifecycle.
    module PostUpdating
      private

      def create_initial_post(text)
        result = @context.mattermost.create_post(channel_id: @context.channel_id, message: text,
                                                 root_id: @context.thread_id)
        post_id = result["id"]
        return handle_create_failure unless post_id

        @post_state.reply_post_id = post_id
        @post_state.last_update_at = Time.now
      end

      def handle_create_failure
        @post_state.create_failed = true
        log(:error, "Failed to create post for thread #{short_id} \u2014 subsequent text will be dropped")
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
    end

    # Finalization: completes the response and handles multi-segment posts.
    module Finalization
      private

      def finalize
        ps = @post_state
        ps.debounce_timer&.join(1)
        stop_typing
        return if finalize_empty?(ps)

        final_text = build_final_text
        apply_final_text(ps, final_text)
      end

      def finalize_empty?(post_state)
        post_state.full_text.empty? && !post_state.reply_post_id
      end

      def apply_final_text(post_state, final_text)
        if only_text_segments?
          post_state.full_text = final_text
          update_post if post_state.reply_post_id
        else
          remove_last_text_from_streamed_post
          create_notification_post(final_text)
        end
      end

      def only_text_segments?
        @segments.none? { |segment| tool_segment?(segment) }
      end

      def build_final_text
        last_text = @segments.reverse.find { |segment| !tool_segment?(segment) }
        last_text || @post_state.full_text
      end

      def remove_last_text_from_streamed_post
        return unless posted?

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
    end

    include PostUpdating
    include Finalization

    def handle_tool_use_display(tool_use)
      return if tool_use[:name] == "AskUserQuestion"

      @segments << format_tool_use(tool_use)
      @post_state.full_text = @segments.join("\n\n")
      stop_typing

      return if @post_state.create_failed
      return create_initial_post(@post_state.full_text) unless posted?

      schedule_update
    end

    def format_tool_use(tool_use)
      name, input = tool_use.values_at(:name, :input)
      format_tool_display(name, input)
    end

    def tool_segment?(segment)
      TOOL_PREFIXES.any? { |prefix| segment.start_with?(prefix) }
    end

    def short_id
      @context.thread_id[0..7]
    end
  end
end
