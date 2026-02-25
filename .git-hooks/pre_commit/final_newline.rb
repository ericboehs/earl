# frozen_string_literal: true

module Overcommit
  module Hook
    module PreCommit
      # Checks that all files end with a final newline character.
      class FinalNewline < Base
        def run
          messages = text_files.filter_map do |file|
            next if File.empty?(file)

            "#{file}: No newline at end of file" unless ends_with_newline?(file)
          end
          messages.map { |msg| Overcommit::Hook::Message.new(:error, nil, nil, msg) }
        end

        private

        def ends_with_newline?(file)
          File.open(file, "rb") do |f|
            f.seek(-1, IO::SEEK_END)
            f.read(1) == "\n"
          end
        end

        def text_files
          result = execute(%w[git ls-files --eol -z --], args: applicable_files)
          return applicable_files unless result.success?

          result.stdout.split("\0").filter_map do |file_info|
            info, path = file_info.split("\t")
            next if info.include?("-text")

            path
          end
        end
      end
    end
  end
end
