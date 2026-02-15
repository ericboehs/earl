require "test_helper"

class Earl::QuestionHandlerTest < ActiveSupport::TestCase
  setup do
    Earl.logger = Logger.new(File::NULL)
  end

  teardown do
    Earl.logger = nil
  end

  test "handle_tool_use ignores non-AskUserQuestion tools" do
    handler = build_handler
    result = handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: { id: "tu-1", name: "Bash", input: { "command" => "ls" } }
    )

    assert_nil result
  end

  test "handle_tool_use ignores empty questions" do
    handler = build_handler
    result = handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: { id: "tu-1", name: "AskUserQuestion", input: { "questions" => [] } }
    )

    assert_nil result
  end

  test "handle_tool_use posts question with options" do
    posted = []
    reactions = []
    handler = build_handler(posted: posted, reactions: reactions)

    handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Which framework?",
              "options" => [
                { "label" => "Rails", "description" => "Ruby on Rails" },
                { "label" => "Sinatra", "description" => "Lightweight Ruby" }
              ]
            }
          ]
        }
      }
    )

    assert_equal 1, posted.size
    assert_includes posted.first[:message], "Which framework?"
    assert_includes posted.first[:message], "Rails"
    assert_includes posted.first[:message], "Sinatra"
    assert_equal 2, reactions.size
    assert_equal "one", reactions[0][:emoji_name]
    assert_equal "two", reactions[1][:emoji_name]
  end

  test "handle_reaction returns nil for unknown post" do
    handler = build_handler
    result = handler.handle_reaction(post_id: "unknown-post", emoji_name: "one")

    assert_nil result
  end

  test "handle_reaction returns nil for non-numbered emoji" do
    posted = []
    reactions = []
    handler = build_handler(posted: posted, reactions: reactions)

    handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Pick one?",
              "options" => [
                { "label" => "A" },
                { "label" => "B" }
              ]
            }
          ]
        }
      }
    )

    # Find the post_id from the handler's state
    post_id = posted.last[:post_id]
    result = handler.handle_reaction(post_id: post_id, emoji_name: "smile")

    assert_nil result
  end

  test "single question flow returns answer on reaction" do
    posted = []
    reactions = []
    handler = build_handler(posted: posted, reactions: reactions)

    handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Pick one?",
              "options" => [
                { "label" => "Option A" },
                { "label" => "Option B" }
              ]
            }
          ]
        }
      }
    )

    post_id = posted.last[:post_id]
    result = handler.handle_reaction(post_id: post_id, emoji_name: "two")

    assert_not_nil result
    assert_equal "tu-1", result[:tool_use_id]
    assert_includes result[:answer_text], "Option B"
  end

  test "handle_reaction deletes question post after answering" do
    posted = []
    reactions = []
    deleted = []
    handler = build_handler(posted: posted, reactions: reactions, deleted: deleted)

    handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Pick one?",
              "options" => [
                { "label" => "Option A" },
                { "label" => "Option B" }
              ]
            }
          ]
        }
      }
    )

    post_id = posted.last[:post_id]
    handler.handle_reaction(post_id: post_id, emoji_name: "one")

    assert_equal 1, deleted.size
    assert_equal post_id, deleted.first
  end

  test "handle_reaction returns nil for out-of-range option" do
    posted = []
    reactions = []
    handler = build_handler(posted: posted, reactions: reactions)

    handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Pick?",
              "options" => [
                { "label" => "Only" }
              ]
            }
          ]
        }
      }
    )

    post_id = posted.last[:post_id]
    # "two" is index 1, but only 1 option exists
    result = handler.handle_reaction(post_id: post_id, emoji_name: "two")

    assert_nil result
  end

  test "multi-question flow posts second question after first answer" do
    posted = []
    reactions = []
    deleted = []
    handler = build_handler(posted: posted, reactions: reactions, deleted: deleted)

    handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "First question?",
              "options" => [
                { "label" => "A" },
                { "label" => "B" }
              ]
            },
            {
              "question" => "Second question?",
              "options" => [
                { "label" => "X" },
                { "label" => "Y" }
              ]
            }
          ]
        }
      }
    )

    # Answer first question
    first_post_id = posted.last[:post_id]
    result = handler.handle_reaction(post_id: first_post_id, emoji_name: "one")

    # Should return nil (more questions to ask)
    assert_nil result
    # Second question should have been posted
    assert_equal 2, posted.size
    assert_includes posted.last[:message], "Second question?"

    # Answer second question
    second_post_id = posted.last[:post_id]
    result = handler.handle_reaction(post_id: second_post_id, emoji_name: "two")

    # Now should return the combined answer
    assert_not_nil result
    assert_includes result[:answer_text], "First question?"
    assert_includes result[:answer_text], "Second question?"
    assert_includes result[:answer_text], "A"
    assert_includes result[:answer_text], "Y"
  end

  test "handle_tool_use passes channel_id to post" do
    posted = []
    reactions = []
    handler = build_handler(posted: posted, reactions: reactions)

    handler.handle_tool_use(
      thread_id: "thread-1",
      channel_id: "channel-789",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Which one?",
              "options" => [
                { "label" => "A" },
                { "label" => "B" }
              ]
            }
          ]
        }
      }
    )

    assert_equal 1, posted.size
    assert_equal "channel-789", posted.first[:channel_id]
  end

  test "handle_tool_use returns tool_use_id hash" do
    handler = build_handler
    result = handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-42",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Pick?",
              "options" => [
                { "label" => "X" },
                { "label" => "Y" }
              ]
            }
          ]
        }
      }
    )

    assert_equal({ tool_use_id: "tu-42" }, result)
  end

  test "options without descriptions display without dash" do
    posted = []
    handler = build_handler(posted: posted)

    handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Pick?",
              "options" => [
                { "label" => "NoDescript" }
              ]
            }
          ]
        }
      }
    )

    message = posted.first[:message]
    assert_includes message, "NoDescript"
    assert_not_includes message, " — "
  end

  test "options with descriptions include dash separator" do
    posted = []
    handler = build_handler(posted: posted)

    handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Pick?",
              "options" => [
                { "label" => "Rails", "description" => "Ruby on Rails" }
              ]
            }
          ]
        }
      }
    )

    message = posted.first[:message]
    assert_includes message, "Rails — Ruby on Rails"
  end

  test "delete_question_post handles error gracefully" do
    posted = []
    reactions = []
    handler = build_handler(posted: posted, reactions: reactions)

    # Override delete_post to raise
    mm = handler.instance_variable_get(:@mattermost)
    mm.define_singleton_method(:delete_post) { |post_id:| raise "delete failed" }

    handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Pick?",
              "options" => [
                { "label" => "A" },
                { "label" => "B" }
              ]
            }
          ]
        }
      }
    )

    post_id = posted.last[:post_id]
    # Should not raise despite delete_post raising
    assert_nothing_raised do
      handler.handle_reaction(post_id: post_id, emoji_name: "one")
    end
  end

  test "handle_tool_use returns error answer when create_post fails" do
    mock_mm = Object.new
    mock_mm.define_singleton_method(:create_post) { |**_args| {} } # No "id"
    mock_mm.define_singleton_method(:add_reaction) { |**_args| }

    handler = Earl::QuestionHandler.new(mattermost: mock_mm)

    result = handler.handle_tool_use(
      thread_id: "thread-1",
      tool_use: {
        id: "tu-1",
        name: "AskUserQuestion",
        input: {
          "questions" => [
            {
              "question" => "Pick?",
              "options" => [ { "label" => "A" }, { "label" => "B" } ]
            }
          ]
        }
      }
    )

    assert_not_nil result
    assert_equal "tu-1", result[:tool_use_id]
    assert_includes result[:answer_text], "Failed to post question"
  end

  private

  def build_handler(posted: [], reactions: [], deleted: [])
    pstd = posted
    rxns = reactions
    dltd = deleted
    post_counter = [ 0 ]

    mock_mm = Object.new
    mock_mm.define_singleton_method(:create_post) do |channel_id:, message:, root_id:|
      post_counter[0] += 1
      post_id = "question-post-#{post_counter[0]}"
      pstd << { channel_id: channel_id, message: message, root_id: root_id, post_id: post_id }
      { "id" => post_id }
    end
    mock_mm.define_singleton_method(:add_reaction) do |post_id:, emoji_name:|
      rxns << { post_id: post_id, emoji_name: emoji_name }
    end
    mock_mm.define_singleton_method(:delete_post) do |post_id:|
      dltd << post_id
    end

    Earl::QuestionHandler.new(mattermost: mock_mm)
  end
end
