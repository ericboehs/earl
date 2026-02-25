# frozen_string_literal: true

require_relative "lib/earl/version"

Gem::Specification.new do |spec|
  spec.name = "earl-bot"
  spec.version = Earl::VERSION
  spec.authors = ["Eric Boehs"]
  spec.email = ["ericboehs@gmail.com"]

  spec.summary = "A Mattermost bot that spawns Claude Code CLI sessions"
  spec.description = "EARL (Eric's Automated Response Line) connects to Mattermost via " \
                     "WebSocket, listens for messages, spawns Claude Code CLI sessions, and " \
                     "streams responses back as threaded replies."
  spec.homepage = "https://github.com/ericboehs/earl"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/ericboehs/earl"
  spec.metadata["changelog_uri"] = "https://github.com/ericboehs/earl/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").select { |f| File.exist?(f) }.reject do |f|
      f.start_with?("test/", "docs/", ".github/", ".") && !f.start_with?(".ruby-version")
    end
  end
  spec.bindir = "exe"
  spec.executables = %w[earl earl-install earl-permission-server]
  spec.require_paths = ["lib"]

  spec.add_dependency "websocket-client-simple", "~> 0.9"

  spec.add_development_dependency "bundler-audit", "~> 0.9"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "reek", "~> 6.0"
  spec.add_development_dependency "rubocop", "~> 1.0"
  spec.add_development_dependency "rubocop-rake", "~> 0.7"
  spec.add_development_dependency "simplecov", "~> 0.22"
end
