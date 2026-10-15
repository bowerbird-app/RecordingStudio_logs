# frozen_string_literal: true

module RecordingStudioLogs
  class Error < StandardError; end

  class InvalidRegistration < Error; end

  class UnknownAggregation < Error; end

  class NotReady < Error; end
end
