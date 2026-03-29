# frozen_string_literal: true

require "test_helper"

module Earl
  # Tests for thread-safe message queue: claiming, enqueueing, injection, and consolidation.
  class MessageQueueTest < Minitest::Test
    setup do
      Earl.logger = Logger.new(File::NULL)
      @queue = Earl::MessageQueue.new
    end

    teardown do
      Earl.logger = nil
    end

    test "try_claim returns true for a new thread_id" do
      assert @queue.try_claim("thread-1")
    end

    test "try_claim returns false when thread is already claimed" do
      @queue.try_claim("thread-1")
      assert_not @queue.try_claim("thread-1")
    end

    test "try_claim allows claiming different thread_ids" do
      assert @queue.try_claim("thread-1")
      assert @queue.try_claim("thread-2")
    end

    test "enqueue stores messages for a claimed thread" do
      @queue.try_claim("thread-1")
      @queue.enqueue("thread-1", "hello")
      @queue.enqueue("thread-1", "world")

      assert_equal "hello", @queue.dequeue("thread-1")
      assert_equal "world", @queue.dequeue("thread-1")
    end

    test "dequeue returns messages in FIFO order" do
      @queue.try_claim("thread-1")
      @queue.enqueue("thread-1", "first")
      @queue.enqueue("thread-1", "second")
      @queue.enqueue("thread-1", "third")

      assert_equal "first", @queue.dequeue("thread-1")
      assert_equal "second", @queue.dequeue("thread-1")
      assert_equal "third", @queue.dequeue("thread-1")
    end

    test "dequeue returns nil and releases claim when queue is empty" do
      @queue.try_claim("thread-1")

      assert_nil @queue.dequeue("thread-1")
      # Thread is now released, so we can claim it again
      assert @queue.try_claim("thread-1")
    end

    test "dequeue keeps claim when messages remain" do
      @queue.try_claim("thread-1")
      @queue.enqueue("thread-1", "hello")
      @queue.enqueue("thread-1", "world")

      @queue.dequeue("thread-1")
      # Thread should still be claimed
      assert_not @queue.try_claim("thread-1")
    end

    test "dequeue on unclaimed thread returns nil" do
      assert_nil @queue.dequeue("thread-1")
    end

    test "full lifecycle: claim, enqueue, drain, release, reclaim" do
      assert @queue.try_claim("thread-1")
      assert_not @queue.try_claim("thread-1")

      @queue.enqueue("thread-1", "msg-1")
      @queue.enqueue("thread-1", "msg-2")

      assert_equal "msg-1", @queue.dequeue("thread-1")
      assert_equal "msg-2", @queue.dequeue("thread-1")
      assert_nil @queue.dequeue("thread-1")

      # Now reclaim should work
      assert @queue.try_claim("thread-1")
    end

    test "independent threads do not interfere" do
      @queue.try_claim("thread-1")
      @queue.try_claim("thread-2")

      @queue.enqueue("thread-1", "for-1")
      @queue.enqueue("thread-2", "for-2")

      assert_equal "for-1", @queue.dequeue("thread-1")
      assert_equal "for-2", @queue.dequeue("thread-2")
    end

    test "release unconditionally frees the claim for a thread" do
      @queue.try_claim("thread-1")
      @queue.enqueue("thread-1", "msg-1")
      @queue.enqueue("thread-1", "msg-2")

      @queue.release("thread-1")

      # Thread can now be re-claimed
      assert @queue.try_claim("thread-1")
    end

    test "release discards pending messages" do
      @queue.try_claim("thread-1")
      @queue.enqueue("thread-1", "msg-1")

      @queue.release("thread-1")

      # After release, dequeue returns nil (no leftover messages)
      assert_nil @queue.dequeue("thread-1")
    end

    test "release is safe to call on unclaimed thread" do
      assert_nothing_raised { @queue.release("thread-1") }
      # Can still claim after no-op release
      assert @queue.try_claim("thread-1")
    end

    test "complete_turn always returns no_pending_turns" do
      assert_equal :no_pending_turns, @queue.complete_turn("thread-1")
    end

    test "complete_turn clears pending turns after inject" do
      @queue.inject("thread-1")
      assert @queue.pending_turns?("thread-1")
      @queue.complete_turn("thread-1")
      assert_not @queue.pending_turns?("thread-1")
    end

    test "release clears pending turns" do
      @queue.try_claim("thread-1")
      @queue.inject("thread-1")
      @queue.release("thread-1")
      assert_equal :no_pending_turns, @queue.complete_turn("thread-1")
    end

    test "pending_turns? returns false when no turns are pending" do
      assert_not @queue.pending_turns?("thread-1")
    end

    test "pending_turns? returns true after inject" do
      @queue.inject("thread-1")
      assert @queue.pending_turns?("thread-1")
    end

    test "pending_turns? returns false after inject and complete_turn" do
      @queue.inject("thread-1")
      @queue.complete_turn("thread-1")
      assert_not @queue.pending_turns?("thread-1")
    end

    test "dequeue_all returns all pending messages and keeps claim" do
      @queue.try_claim("thread-1")
      @queue.enqueue("thread-1", "msg-1")
      @queue.enqueue("thread-1", "msg-2")
      @queue.enqueue("thread-1", "msg-3")

      result = @queue.dequeue_all("thread-1")
      assert_equal %w[msg-1 msg-2 msg-3], result
      # Claim should still be held (messages were present)
      assert_not @queue.try_claim("thread-1")
    end

    test "dequeue_all returns empty array and releases claim when no messages" do
      @queue.try_claim("thread-1")

      result = @queue.dequeue_all("thread-1")
      assert_equal [], result
      # Claim should be released
      assert @queue.try_claim("thread-1")
    end

    test "dequeue_all clears the queue" do
      @queue.try_claim("thread-1")
      @queue.enqueue("thread-1", "msg-1")

      @queue.dequeue_all("thread-1")
      # Subsequent dequeue_all should be empty
      result = @queue.dequeue_all("thread-1")
      assert_equal [], result
    end

    test "enqueue and dequeue preserves UserMessage objects" do
      @queue.try_claim("thread-1")
      msg = Earl::Runner::UserMessage.new(
        thread_id: "thread-1", text: "hello", channel_id: "ch-1",
        sender_name: "alice", file_ids: %w[file-1 file-2]
      )
      @queue.enqueue("thread-1", msg)

      result = @queue.dequeue("thread-1")
      assert_instance_of Earl::Runner::UserMessage, result
      assert_equal "hello", result.text
      assert_equal %w[file-1 file-2], result.file_ids
    end
  end
end
