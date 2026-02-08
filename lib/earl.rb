# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "logger"
require "open3"
require "securerandom"

require_relative "earl/config"
require_relative "earl/mattermost"
require_relative "earl/claude_session"
require_relative "earl/session_manager"
require_relative "earl/runner"

module Earl
  def self.logger
    @logger ||= Logger.new($stdout, level: Logger::INFO).tap do |log|
      log.formatter = proc do |severity, datetime, _progname, msg|
        "#{datetime.strftime('%H:%M:%S')} [#{severity}] #{msg}\n"
      end
    end
  end

  def self.logger=(logger)
    @logger = logger
  end
end
