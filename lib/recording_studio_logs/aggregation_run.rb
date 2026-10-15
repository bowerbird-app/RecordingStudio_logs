# frozen_string_literal: true

module RecordingStudioLogs
  class AggregationRun < ActiveRecord::Base
    self.table_name = "recording_studio_logs_aggregation_runs"

    def self.record!(aggregation_name:, day:, status:, error_message: nil)
      run = find_or_initialize_by(aggregation_name: aggregation_name, day: day)
      run.status = status
      run.error_message = error_message
      run.finished_at = Time.current
      run.save!
      run
    end

    def self.succeeded?(aggregation_name, days)
      where(aggregation_name: aggregation_name, day: days, status: "succeeded").count == days.size
    end
  end
end
