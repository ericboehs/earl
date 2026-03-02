# frozen_string_literal: true

require_relative "cli/heartbeat"
require_relative "cli/thread"

module Earl
  # CLI dispatcher for subcommands (heartbeat, thread).
  # Called from exe/earl when ARGV[0] matches a known subcommand.
  module Cli
    COMMANDS = {
      "heartbeat" => Cli::Heartbeat,
      "thread" => Cli::Thread
    }.freeze

    def self.run(argv)
      command_name = argv[0]
      handler = COMMANDS[command_name]
      unless handler
        warn "Unknown command: #{command_name}"
        exit 1
      end

      handler.run(argv.drop(1))
    end
  end
end
