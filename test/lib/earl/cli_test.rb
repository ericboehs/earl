# frozen_string_literal: true

require "test_helper"

module Earl
  class CliTest < Minitest::Test
    test "run dispatches known command to handler" do
      called_with = nil
      original_run = Cli::Heartbeat.method(:run)
      stub_singleton(Cli::Heartbeat, :run) { |argv| called_with = argv }

      Cli.run(%w[heartbeat list])
      assert_equal %w[list], called_with
    ensure
      stub_singleton(Cli::Heartbeat, :run) { |*args| original_run.call(*args) }
    end

    test "run exits with error for unknown command" do
      error = assert_raises(SystemExit) { capture_io { Cli.run(%w[nope]) } }
      assert_equal 1, error.status
    end
  end
end
