# frozen_string_literal: true

module Earl
  class Runner
    DEBOUNCE_MS = 300

    def initialize
      @config = Config.new
      @session_manager = SessionManager.new
      @mattermost = Mattermost.new(@config)
      @shutting_down = false
    end

    def start
      setup_signal_handlers
      setup_message_handler
      @mattermost.connect

      Earl.logger.info "EARL is running. Listening for messages in channel #{@config.channel_id[0..7]}..."
      Earl.logger.info "Allowed users: #{@config.allowed_users.join(', ')}"

      # Keep main thread alive
      sleep 0.5 until @shutting_down
    end

    private

    def setup_signal_handlers
      %w[INT TERM].each do |signal|
        trap(signal) do
          return if @shutting_down
          @shutting_down = true

          Thread.new do
            Earl.logger.info "Shutting down..."
            @session_manager.stop_all
            Earl.logger.info "Goodbye!"
            exit 0
          end
        end
      end
    end

    def setup_message_handler
      @mattermost.on_message do |sender_name:, thread_id:, text:, post_id:|
        if allowed_user?(sender_name)
          handle_message(sender_name: sender_name, thread_id: thread_id, text: text)
        end
      end
    end

    def allowed_user?(username)
      return true if @config.allowed_users.empty?

      unless @config.allowed_users.include?(username)
        Earl.logger.debug "Ignoring message from non-allowed user: #{username}"
        return false
      end

      true
    end

    def handle_message(sender_name:, thread_id:, text:)
      session = @session_manager.get_or_create(thread_id)

      # Start typing indicator (repeats every 3s until stopped)
      typing_thread = start_typing(thread_id)

      # Per-message streaming state — shared across callbacks
      state = {
        reply_post_id: nil,
        full_text: "",
        last_update_at: Time.now,
        debounce_timer: nil,
        typing_thread: typing_thread,
        mutex: Mutex.new
      }

      session.on_text do |accumulated_text|
        state[:mutex].synchronize do
          state[:full_text] = accumulated_text

          # Stop typing indicator once we start posting
          stop_typing(state[:typing_thread])
          state[:typing_thread] = nil

          if state[:reply_post_id].nil?
            # First chunk — create the reply post
            result = @mattermost.create_post(
              channel_id: @config.channel_id,
              message: accumulated_text,
              root_id: thread_id
            )
            state[:reply_post_id] = result["id"]
            state[:last_update_at] = Time.now
          else
            elapsed_ms = (Time.now - state[:last_update_at]) * 1000

            if elapsed_ms >= DEBOUNCE_MS
              # Enough time has passed — update immediately
              state[:debounce_timer] = nil
              @mattermost.update_post(post_id: state[:reply_post_id], message: state[:full_text])
              state[:last_update_at] = Time.now
            elsif state[:debounce_timer].nil?
              # Schedule a debounced update
              state[:debounce_timer] = Thread.new do
                sleep DEBOUNCE_MS / 1000.0
                state[:mutex].synchronize do
                  state[:debounce_timer] = nil
                  @mattermost.update_post(post_id: state[:reply_post_id], message: state[:full_text])
                  state[:last_update_at] = Time.now
                end
              end
            end
            # If timer already scheduled, it will pick up the latest full_text when it fires
          end
        end
      end

      session.on_complete do |_sess|
        stop_typing(state[:typing_thread])
        state[:typing_thread] = nil

        state[:mutex].synchronize do
          if state[:reply_post_id] && !state[:full_text].empty?
            @mattermost.update_post(post_id: state[:reply_post_id], message: state[:full_text])
          end
        end
        Earl.logger.info "Response complete for thread #{thread_id[0..7]} (cost=$#{session.total_cost})"
      end

      session.send_message(text)
    end

    def start_typing(thread_id)
      Thread.new do
        loop do
          @mattermost.send_typing(channel_id: @config.channel_id, parent_id: thread_id)
          sleep 3
        rescue => e
          Earl.logger.debug "Typing indicator error: #{e.message}"
          break
        end
      end
    end

    def stop_typing(thread)
      thread&.kill
    end
  end
end
