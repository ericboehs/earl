# frozen_string_literal: true

module Earl
  class TmuxMonitor
    # Handles forwarding detected questions from tmux panes to Mattermost
    # and processing user reactions back as tmux keyboard input.
    class QuestionForwarder
      include Logging

      EMOJI_NUMBERS = QuestionHandler::EMOJI_NUMBERS
      EMOJI_MAP = QuestionHandler::EMOJI_MAP

      def initialize(mattermost:, tmux:, pending_interactions:, mutex:)
        @mattermost = mattermost
        @tmux = tmux
        @pending_interactions = pending_interactions
        @mutex = mutex
      end

      def forward(name, output, info)
        parsed = parse_question(output)
        return unless parsed

        post = post_question(name, parsed, info)
        return unless post

        register_interaction(post, name, parsed[:options])
      end

      def handle_reaction(interaction, emoji_name, post_id)
        answer_index = EMOJI_MAP[emoji_name]
        return nil unless answer_index
        return nil unless valid_option?(interaction, answer_index)

        send_answer(interaction, answer_index, post_id)
      end

      def parse_question(output)
        lines = output.lines.map(&:strip).reject(&:empty?)
        question_idx = find_question_index(lines)
        return nil unless question_idx

        build_parsed(lines, question_idx)
      end

      private

      def valid_option?(interaction, answer_index)
        answer_index < interaction[:options].size
      end

      def find_question_index(lines)
        lines.rindex { |line| line.include?("?") }
      end

      def build_parsed(lines, question_idx)
        options = gather_numbered_options(lines, question_idx).first(4)
        return nil if options.empty?

        { text: lines[question_idx], options: options }
      end

      def send_answer(interaction, answer_index, post_id)
        @tmux.send_keys(interaction[:session_name], (answer_index + 1).to_s)
        @mutex.synchronize { @pending_interactions.delete(post_id) }
        true
      rescue Tmux::Error => error
        log(:error, "TmuxMonitor: failed to send question answer: #{error.message}")
        nil
      end

      def gather_numbered_options(lines, question_idx)
        options = []
        (question_idx + 1...lines.size).each do |idx|
          line = lines[idx]
          options << line.sub(/\A\s*\d+[\.\)]\s*/, "") if line.match?(/\A\s*\d+[\.\)]\s/)
        end
        options
      end

      def post_question(name, parsed, info)
        message = build_question_message(name, parsed)
        @mattermost.create_post(
          channel_id: info.channel_id,
          message: message,
          root_id: info.thread_id
        )
      rescue StandardError => error
        log(:error, "TmuxMonitor: failed to post alert (#{error.class}): #{error.message}")
        nil
      end

      def build_question_message(name, parsed)
        lines = [ ":question: **Tmux `#{name}`** is asking:", "```", parsed[:text], "```" ]
        parsed[:options].each_with_index do |opt, idx|
          emoji = EMOJI_NUMBERS[idx]
          lines << ":#{emoji}: #{opt}" if emoji
        end
        lines.join("\n")
      end

      def register_interaction(post, name, options)
        post_id = post["id"]
        return unless post_id

        add_emoji_reactions(post_id, options.size)
        @mutex.synchronize do
          @pending_interactions[post_id] = {
            session_name: name, type: :question, options: options
          }
        end
      end

      def add_emoji_reactions(post_id, count)
        [ count, EMOJI_NUMBERS.size ].min.times do |idx|
          emoji = EMOJI_NUMBERS[idx]
          @mattermost.add_reaction(post_id: post_id, emoji_name: emoji)
        rescue StandardError => error
          log(:warn, "TmuxMonitor: failed to add reaction :#{emoji}: (#{error.class}): #{error.message}")
        end
      end
    end
  end
end
