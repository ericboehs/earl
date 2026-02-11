# frozen_string_literal: true

require "test_helper"

class Earl::MessageQueueTest < ActiveSupport::TestCase
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
end
