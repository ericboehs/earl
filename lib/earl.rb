# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "logger"
require "open3"
require "securerandom"
require "fileutils"
require "tmpdir"
require "time"

require_relative "earl/version"
require_relative "earl/logging"
require_relative "earl/formatting"
require_relative "earl/permission_config"
require_relative "earl/tool_input_formatter"
require_relative "earl/config"
require_relative "earl/mattermost"
require_relative "earl/claude_session"
require_relative "earl/session_store"
require_relative "earl/session_manager"
require_relative "earl/streaming_response"
require_relative "earl/message_queue"
require_relative "earl/image_support/content_builder"
require_relative "earl/image_support/output_detector"
require_relative "earl/image_support/uploader"
require_relative "earl/command_parser"
require_relative "earl/command_executor"
require_relative "earl/question_handler"
require_relative "earl/mcp/config"
require_relative "earl/mcp/handler_base"
require_relative "earl/mcp/approval_handler"
require_relative "earl/mcp/memory_handler"
require_relative "earl/mcp/heartbeat_handler"
require_relative "earl/mcp/tmux_handler"
require_relative "earl/mcp/pearl_handler"
require_relative "earl/mcp/github_pat_handler"
require_relative "earl/mcp/mattermost_handler"
require_relative "earl/mcp/server"
require_relative "earl/memory/store"
require_relative "earl/memory/prompt_builder"
require_relative "earl/cron_parser"
require_relative "earl/heartbeat_config"
require_relative "earl/heartbeat_scheduler"
require_relative "earl/safari_automation"
require_relative "earl/tmux"
require_relative "earl/tmux_session_store"
require_relative "earl/tmux_monitor"
require_relative "earl/runner/thread_context_builder"
require_relative "earl/runner/service_builder"
require_relative "earl/runner/startup"
require_relative "earl/runner/lifecycle"
require_relative "earl/runner/message_handling"
require_relative "earl/runner/reaction_handling"
require_relative "earl/runner/response_lifecycle"
require_relative "earl/runner/idle_management"
require_relative "earl/runner"

# Top-level module for EARL (Eric's Automated Response Line), a Mattermost bot
# that bridges team chat with Claude AI sessions for interactive assistance.
module Earl
  VALID_ENVIRONMENTS = %w[production development].freeze

  def self.env
    @env ||= ENV.fetch("EARL_ENV", "production").tap do |value|
      unless VALID_ENVIRONMENTS.include?(value)
        raise ArgumentError, "Invalid EARL_ENV=#{value.inspect}. Valid: #{VALID_ENVIRONMENTS.join(", ")}"
      end
    end
  end

  def self.development?
    env == "development"
  end

  def self.config_root
    @config_root ||= File.join(Dir.home, ".config", development? ? "earl-dev" : "earl")
  end

  def self.claude_home
    ENV.fetch("EARL_CLAUDE_HOME", File.join(config_root, "claude-home"))
  end

  def self.logger
    @logger ||= Logger.new($stdout, level: Logger::INFO).tap do |log|
      log.formatter = proc do |severity, datetime, _progname, msg|
        "#{datetime.strftime("%H:%M:%S")} [#{severity}] #{msg}\n"
      end
    end
  end

  def self.logger=(logger)
    @logger = logger
  end
end
