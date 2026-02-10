# frozen_string_literal: true

module Earl
  # Manages the lifecycle of a single streamed response to Mattermost,
  # including post creation, debounced updates, and typing indicators.
  class StreamingResponse
    include Logging
    DEBOUNCE_MS = 300

    def initialize(thread_id:, mattermost:, channel_id:)
      @thread_id = thread_id
      @mattermost = mattermost
      @channel_id = channel_id
      @reply_post_id = nil
      @full_text = ""
      @last_update_at = Time.now
      @debounce_timer = nil
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
    end

    private

    def typing_loop
      loop do
        send_typing_indicator
        sleep 3
      rescue StandardError => error
        log(:warn, "Typing error (thread #{short_id}): #{error.class}: #{error.message}")
        break
      end
    end

    def send_typing_indicator
      @mattermost.send_typing(channel_id: @channel_id, parent_id: @thread_id)
    end

    def handle_text(text)
      @full_text = text
      stop_typing

      return create_initial_post(text) unless @reply_post_id

      schedule_update
    end

    def create_initial_post(text)
      post_id = @mattermost.create_post(channel_id: @channel_id, message: text, root_id: @thread_id)["id"]
      @reply_post_id = post_id if post_id
      @last_update_at = Time.now
    end

    def schedule_update
      elapsed_ms = (Time.now - @last_update_at) * 1000

      if elapsed_ms >= DEBOUNCE_MS
        update_post
      else
        start_debounce_timer
      end
    end

    def start_debounce_timer
      return if @debounce_timer

      @debounce_timer = Thread.new do
        sleep DEBOUNCE_MS / 1000.0
        @mutex.synchronize { update_post }
      end
    end

    def update_post
      @debounce_timer = nil
      @mattermost.update_post(post_id: @reply_post_id, message: @full_text)
      @last_update_at = Time.now
    end

    def finalize
      stop_typing
      update_post if @reply_post_id && !@full_text.empty?
    end

    def stop_typing
      @typing_thread&.kill
      @typing_thread = nil
    end

    def short_id
      @thread_id[0..7]
    end
  end
end
