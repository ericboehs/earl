# frozen_string_literal: true

module Earl
  # Shared logging convenience for EARL classes, delegating to Earl.logger.
  module Logging
    private

    def log(level, message)
      Earl.logger.public_send(level, message)
    end
  end
end
