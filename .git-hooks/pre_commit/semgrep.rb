# frozen_string_literal: true

module Overcommit
  module Hook
    module PreCommit
      # Runs Semgrep static analysis on staged Ruby files.
      class Semgrep < Base
        def run
          ruby_files = applicable_files.select { |f| f.end_with?(".rb") }
          return :pass if ruby_files.empty?

          result = execute(%w[semgrep --config=r/ruby --metrics=off --error --quiet], args: ruby_files)
          return :pass if result.success?

          [Overcommit::Hook::Message.new(:error, nil, nil, result.stdout + result.stderr)]
        end
      end
    end
  end
end
