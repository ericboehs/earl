# frozen_string_literal: true

module Earl
  # Thread-safe message queue that tracks which threads are actively
  # processing and buffers messages for busy threads.
  class MessageQueue
    include Logging

    def initialize
      @processing_threads = Set.new
      @pending_messages = {}
      @mutex = Mutex.new
    end

    def try_claim(thread_id)
      @mutex.synchronize do
        if @processing_threads.include?(thread_id)
          false
        else
          @processing_threads << thread_id
          true
        end
      end
    end

    def enqueue(thread_id, message)
      @mutex.synchronize do
        queue = (@pending_messages[thread_id] ||= [])
        queue << message
        log(:debug, "Queued message for busy thread #{thread_id[0..7]}")
      end
    end

    def dequeue(thread_id)
      @mutex.synchronize do
        msgs = @pending_messages[thread_id]
        if msgs && !msgs.empty?
          msgs.shift
        else
          @processing_threads.delete(thread_id)
          nil
        end
      end
    end

    # Unconditionally releases the processing claim for a thread,
    # discarding any pending messages. Use when the session is dead
    # and queued messages cannot be delivered.
    def release(thread_id)
      @mutex.synchronize do
        @processing_threads.delete(thread_id)
        @pending_messages.delete(thread_id)
      end
    end
  end
end
