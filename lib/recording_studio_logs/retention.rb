# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    module_function

    def normalize(value)
      return :indefinite if [:indefinite, "indefinite"].include?(value)
      return value if value.is_a?(ActiveSupport::Duration) && value.positive?

      raise InvalidRegistration, "retention must be :indefinite or a positive duration"
    end
  end
end
