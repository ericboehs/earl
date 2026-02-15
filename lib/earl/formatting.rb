# frozen_string_literal: true

module Earl
  # Shared formatting helpers for numbers and display.
  module Formatting
    # :reek:UtilityFunction
    def format_number(num)
      return "0" unless num

      num.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse
    end
  end
end
