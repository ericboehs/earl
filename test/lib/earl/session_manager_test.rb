require "test_helper"

class Earl::SessionManagerTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)
  end

  teardown do
    Earl.logger = nil
  end

  test "get_or_create creates new session for unknown thread" do
    manager = Earl::SessionManager.new
    session = create_with_fake_session(manager, "thread-abc12345")

    assert_not_nil session
  end

  test "get_or_create reuses alive session for same thread" do
    manager = Earl::SessionManager.new
    first = create_with_fake_session(manager, "thread-abc12345", alive: true)
    second = manager.get_or_create("thread-abc12345")

    assert_same first, second
  end

  test "get_or_create replaces dead session" do
    manager = Earl::SessionManager.new
    first = create_with_fake_session(manager, "thread-abc12345", alive: false)

    # Second call should create a new session since first is dead
    second = create_with_fake_session(manager, "thread-abc12345")

    assert_not_same first, second
  end

  test "stop_all kills all sessions and clears map" do
    manager = Earl::SessionManager.new
    killed = []

    s1 = create_with_fake_session(manager, "thread-aaa11111") { killed << :a }
    s2 = create_with_fake_session(manager, "thread-bbb22222") { killed << :b }
    s3 = create_with_fake_session(manager, "thread-ccc33333") { killed << :c }

    manager.stop_all

    assert_equal 3, killed.size

    # After stop_all, new requests should create fresh sessions
    fresh = create_with_fake_session(manager, "thread-aaa11111")
    assert_not_same s1, fresh
  end

  private

  def create_with_fake_session(manager, thread_id, alive: true, &on_kill)
    # Temporarily replace the session creation in get_or_create
    # by pre-populating and using the manager's internal map
    session = fake_session(alive: alive, &on_kill)

    # Access internal state to inject our fake
    original_new = Earl::ClaudeSession.method(:new)
    Earl::ClaudeSession.define_singleton_method(:new) { |**_args| session }

    result = manager.get_or_create(thread_id)

    Earl::ClaudeSession.define_singleton_method(:new) { |**args| original_new.call(**args) }

    result
  end

  def fake_session(alive: true, &on_kill)
    session = Object.new
    session.define_singleton_method(:start) { }
    session.define_singleton_method(:alive?) { alive }
    session.define_singleton_method(:kill) { on_kill&.call }
    session
  end
end
