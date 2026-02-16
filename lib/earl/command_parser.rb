# frozen_string_literal: true

module Earl
  # Parses `!` prefixed commands from user messages in Mattermost.
  # Returns a ParsedCommand struct or nil if the message is not a command.
  class CommandParser
    # A parsed chat command with name and arguments.
    ParsedCommand = Struct.new(:name, :args, keyword_init: true)

    COMMANDS = {
      /\A!stop\z/i => :stop,
      /\A!escape\z/i => :escape,
      /\A!kill\z/i => :kill,
      /\A!help\z/i => :help,
      /\A!stats\z/i => :stats,
      /\A!cost\z/i => :stats,
      /\A!compact\z/i => :compact,
      /\A!cd\s+(.+)\z/i => :cd,
      /\A!permissions\z/i => :permissions,
      /\A!heartbeats\z/i => :heartbeats,
      /\A!usage\z/i => :usage,
      /\A!context\z/i => :context,
      /\A!sessions\z/i => :sessions,
      # Specific !session subcommands must come before catch-all
      /\A!session\s+(\S+)\s+status\z/i => :session_status,
      /\A!session\s+(\S+)\s+kill\z/i => :session_kill,
      /\A!session\s+(\S+)\s+nudge\z/i => :session_nudge,
      /\A!session\s+(\S+)\s+approve\z/i => :session_approve,
      /\A!session\s+(\S+)\s+deny\z/i => :session_deny,
      /\A!session\s+(\S+)\s+"([^"]+)"\z/i => :session_input,
      /\A!session\s+(\S+)\s+'([^']+)'\z/i => :session_input,
      /\A!session\s+(\S+)\z/i => :session_show,
      /\A!spawn\s+"([^"]+)"(.*)\z/i => :spawn
    }.freeze

    def self.command?(text)
      text.strip.start_with?("!")
    end

    def self.parse(text)
      stripped = text.strip
      return nil unless stripped.start_with?("!")

      COMMANDS.each do |pattern, name|
        match = stripped.match(pattern)
        next unless match

        args = match.captures
        return ParsedCommand.new(name: name, args: args)
      end

      nil
    end
  end
end
