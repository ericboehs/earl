# frozen_string_literal: true

module Earl
  # Minimal 5-field cron expression parser (minute hour dom month dow).
  # Supports: *, specific values, ranges (1-5), steps (*/15), lists (1,3,5).
  class CronParser
    MAX_SCAN_DAYS = 366

    def initialize(expression)
      @fields = parse_expression(expression)
    end

    # :reek:FeatureEnvy
    def matches?(time)
      minute, hour, dom, month, dow = @fields
      minute.include?(time.min) &&
        hour.include?(time.hour) &&
        dom.include?(time.day) &&
        month.include?(time.month) &&
        dow.include?(time.wday)
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

    def beginning_of_next_minute(time)
      Time.new(time.year, time.month, time.day, time.hour, time.min, 0) + 60
    end

    # :reek:DuplicateMethodCall :reek:FeatureEnvy
    def parse_expression(expression)
      parts = expression.strip.split(/\s+/)
      unless parts.size == 5
        raise ArgumentError, "Invalid cron expression: expected 5 fields, got #{parts.size}"
      end

      [
        parse_field(parts[0], 0..59),  # minute
        parse_field(parts[1], 0..23),  # hour
        parse_field(parts[2], 1..31),  # day of month
        parse_field(parts[3], 1..12),  # month
        parse_field(parts[4], 0..6)    # day of week
      ]
    end

    def parse_field(field, range)
      values = field.split(",").flat_map { |part| parse_part(part.strip, range) }
      values.select { |val| range.include?(val) }.uniq.sort
    end

    # :reek:DuplicateMethodCall :reek:TooManyStatements
    def parse_part(part, range)
      case part
      when "*"
        range.to_a
      when /\A\*\/(\d+)\z/
        step = ::Regexp.last_match(1).to_i
        raise ArgumentError, "Invalid step: #{part}" if step.zero?

        range.step(step).to_a
      when /\A(\d+)-(\d+)\z/
        start_val = ::Regexp.last_match(1).to_i
        end_val = ::Regexp.last_match(2).to_i
        (start_val..end_val).to_a
      when /\A(\d+)-(\d+)\/(\d+)\z/
        start_val = ::Regexp.last_match(1).to_i
        end_val = ::Regexp.last_match(2).to_i
        step = ::Regexp.last_match(3).to_i
        raise ArgumentError, "Invalid step: #{part}" if step.zero?

        (start_val..end_val).step(step).to_a
      when /\A\d+\z/
        [ part.to_i ]
      else
        raise ArgumentError, "Invalid cron field: #{part}"
      end
    end
  end
end
