# frozen_string_literal: true

module Earl
  # Manages the lifecycle of a single streamed response to Mattermost,
  # including post creation, debounced updates, and typing indicators.
  class StreamingResponse
    include Logging
    DEBOUNCE_MS = 300

    # Holds the Mattermost thread and channel context for posting.
    Context = Struct.new(:thread_id, :mattermost, :channel_id, keyword_init: true)
    # Tracks the reply post lifecycle: ID, failure state, text, and debounce timing.
    PostState = Struct.new(:reply_post_id, :create_failed, :full_text, :last_update_at, :debounce_timer, keyword_init: true)

    def initialize(thread_id:, mattermost:, channel_id:)
      @context = Context.new(thread_id: thread_id, mattermost: mattermost, channel_id: channel_id)
      @post_state = PostState.new(create_failed: false, full_text: "", last_update_at: Time.now)
      @typing_thread = nil
      @mutex = Mutex.new
    end

    def start_typing
      @typing_thread = Thread.new { typing_loop }
    end

    def on_text(accumulated_text)
      @mutex.synchronize { handle_text(accumulated_text) }
    rescue StandardError => error
      log(:error, "Streaming error (thread #{short_id}): #{error.class}: #{error.message}")
      log(:error, error.backtrace.first(5).join("\n"))
    end

    def on_complete
      @mutex.synchronize { finalize }
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
      @post_state.full_text = text
      stop_typing

      return if @post_state.create_failed
      return create_initial_post(text) unless @post_state.reply_post_id

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

    def finalize
      stop_typing
      update_post if @post_state.reply_post_id && !@post_state.full_text.empty?
    end

    def stop_typing
      @typing_thread&.kill
      @typing_thread = nil
    end

    def short_id
      @context.thread_id[0..7]
    end
  end
end
