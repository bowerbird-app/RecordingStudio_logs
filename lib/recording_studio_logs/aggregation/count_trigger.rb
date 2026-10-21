# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    module CountTrigger
      extend ActiveSupport::Concern

      included do
        before_save :recording_studio_logs_remember_time
        after_commit :recording_studio_logs_count_period
      end

      module_function

      def install(model)
        return if model.nil? || model.included_modules.include?(self)

        model.include(self)
      end

      def recount(record)
        CountRecounter.call(record)
      end

      private

      def recording_studio_logs_remember_time
        log = RecordingStudioLogs.registry.log_for(self.class)
        return unless log&.loaded?

        @recording_studio_logs_previous_time = attribute_in_database(log.timestamp_column.to_s)
      end

      def recording_studio_logs_count_period
        CountTrigger.recount(self)
      end
    end
  end
end
