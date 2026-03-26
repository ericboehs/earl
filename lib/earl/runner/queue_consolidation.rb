# frozen_string_literal: true

module Earl
  class Runner
    # Drains and consolidates multiple queued messages into a single UserMessage for batch delivery.
    module QueueConsolidation
      # Wraps a batch of queued UserMessages for consolidation.
      class QueuedBatch
        def initialize(messages)
          @messages = messages
        end

        def text      = @messages.map(&:text).join("\n\n")
        def source    = @messages.first
        def file_ids  = @messages.flat_map(&:file_ids)
      end

      private_constant :QueuedBatch

      private

      def process_next_queued(thread_id)
        raw = @app_state.message_queue.dequeue_all(thread_id)
        return if raw.empty?

        messages = raw.map { |msg| normalize_queued(msg, thread_id) }
        return process_message(messages.first) if messages.one?

        process_message(build_consolidated(messages, thread_id))
      end

      def build_consolidated(messages, thread_id)
        batch = QueuedBatch.new(messages)
        source = batch.source
        UserMessage.new(thread_id: thread_id, text: batch.text,
                        channel_id: source.channel_id, sender_name: source.sender_name,
                        file_ids: batch.file_ids)
      end

      def normalize_queued(queued, thread_id)
        return queued if queued.is_a?(UserMessage)

        UserMessage.new(thread_id: thread_id, text: queued.to_s, channel_id: nil, sender_name: nil)
      end
    end
  end
end
