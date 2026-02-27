# frozen_string_literal: true

require "open3"

module Earl
  module Mcp
    class ConversationHandler
      # Creates sanitized GitHub issues via `gh issue create`.
      # Parses PART 2 of the analysis output to extract title, labels, and body,
      # then appends a Mattermost thread permalink.
      module GithubIssue
        ISSUE_TIMEOUT_SECONDS = 30
        DEFAULT_REPO = "ericboehs/earl"

        private

        def create_github_issue(sanitized_body, thread_url)
          title, labels, body = parse_issue_parts(sanitized_body)
          return "Error: could not parse issue title from analysis" unless title

          full_body = "#{body}\n\n---\n\n[Conversation thread](#{thread_url})"
          execute_issue_create(title, labels, full_body)
        end

        def parse_issue_parts(text)
          title = extract_field(text, "Title")
          labels = extract_field(text, "Labels") || "bug"
          body = extract_body(text)
          [title, labels, body]
        end

        def extract_field(text, field_name)
          match = text.match(/^#{field_name}:\s*(.+)$/i)
          match && match[1].strip
        end

        def extract_body(text)
          match = text.match(/^Body:\s*(.+)/im)
          return "No details provided." unless match

          match[1].strip
        end

        def execute_issue_create(title, labels, body)
          repo = ENV.fetch("EARL_GITHUB_REPO", DEFAULT_REPO)
          args = ["gh", "issue", "create", "--repo", repo,
                  "--title", title, "--body", body, "--label", labels]
          # nosemgrep: ruby.lang.security.dangerous-exec.dangerous-exec -- array-form arguments, no shell injection
          output, status = Open3.capture2(*args, err: File::NULL)
          return "Error: gh issue create failed (exit #{status.exitstatus})" unless status.success?

          output.strip
        rescue Errno::ENOENT
          "Error: gh CLI not found"
        end

        def build_thread_url(thread_id)
          base = @config.platform_url
          team_name = ENV.fetch("PLATFORM_TEAM_NAME", "default")
          "#{base}/#{team_name}/pl/#{thread_id}"
        end
      end
    end
  end
end
