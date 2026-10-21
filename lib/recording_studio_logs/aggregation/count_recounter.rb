# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    module CountRecounter
      module_function

      def call(record)
        log = RecordingStudioLogs.registry.log_for(record.class)
        return unless log&.loaded?

        recount(log, times_for(log, record))
      end

      def times_for(log, record)
        [
          record[log.timestamp_column],
          record.instance_variable_get(:@recording_studio_logs_previous_time)
        ].compact.uniq
      end

      def recount(log, times)
        RecordingStudioLogs.registry.aggregations_for(log).each do |definition|
          next unless definition.live_count?
          next if definition.dormant?

          times.each { |time| definition.count_period(definition.period.start_for(time)) }
        end
      end
    end
  end
end
