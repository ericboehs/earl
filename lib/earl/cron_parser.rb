# frozen_string_literal: true

module Earl
  # Minimal 5-field cron expression parser (minute hour dom month dow).
  # Supports: *, specific values, ranges (1-5), steps (*/15), lists (1,3,5).
  class CronParser
    MAX_SCAN_DAYS = 366

    def initialize(expression)
      @fields = parse_expression(expression)
    end

    def matches?(time)
      matches_values?(extract_time_values(time))
    end

    def next_occurrence(from: Time.now)
      # Start scanning from the next whole minute
      candidate = beginning_of_next_minute(from)
      limit = from + (MAX_SCAN_DAYS * 86_400)

      while candidate <= limit
        return candidate if matches?(candidate)

        candidate += 60
      end

      nil
    end

    private

    def extract_time_values(time)
      [time.min, time.hour, time.day, time.month, time.wday]
    end

    def matches_values?(values)
      @fields.zip(values).all? { |allowed, value| allowed.include?(value) }
    end

    def beginning_of_next_minute(time)
      Time.new(time.year, time.month, time.day, time.hour, time.min, 0) + 60
    end

    def parse_expression(expression)
      fields = expression.strip.split(/\s+/)
      count = fields.size
      raise ArgumentError, "Invalid cron expression: expected 5 fields, got #{count}" unless count == 5

      fields.zip(FIELD_RANGES).map { |field, range| parse_field(field, range) }
    end

    FIELD_RANGES = [0..59, 0..23, 1..31, 1..12, 0..6].freeze
    private_constant :FIELD_RANGES

    def parse_field(field, range)
      values = field.split(",").flat_map { |token| PartParser.new(token.strip, range).parse }
      values.select { |val| range.include?(val) }.uniq.sort
    end

    # Parses a single cron field part (e.g. "*/15", "1-5", "3").
    # Encapsulates the part string and valid range as instance state
    # so parsing methods can reference them without parameter passing.
    class PartParser
      def initialize(part, range)
        @part = part
        @range = range
      end

      def parse
        return @range.to_a if @part == "*"
        return [@part.to_i] if @part.match?(/\A\d+\z/)
        return parse_wildcard_step if @part.start_with?("*/")
        return parse_range_step if @part.include?("/")
        return parse_range if @part.include?("-")

        raise ArgumentError, "Invalid cron field: #{@part}"
      end

      private

      def parse_wildcard_step
        step = @part.delete_prefix("*/").to_i
        validated_step(@range, step)
      end

      def parse_range
        left, right = @part.split("-", 2)
        (left.to_i..right.to_i).to_a
      end

      def parse_range_step
        range_str, step_str = @part.split("/", 2)
        left, right = range_str.split("-", 2)
        validated_step(left.to_i..right.to_i, step_str.to_i)
      end

      def validated_step(range, step)
        raise ArgumentError, "Invalid step: #{@part}" if step.zero?

        range.step(step).to_a
      end
    end
  end
end
