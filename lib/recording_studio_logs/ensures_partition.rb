# frozen_string_literal: true

module RecordingStudioLogs
  # Optional callback so a normal create lands in the month partition.
  # insert_all skips callbacks; call ensure_partition! before a bulk insert.
  module EnsuresPartition
    extend ActiveSupport::Concern

    included do
      before_create :recording_studio_logs_ensure_partition
    end

    private

    def recording_studio_logs_ensure_partition
      log = RecordingStudioLogs.registry.log_for(self.class)
      return unless log&.partitioned?

      Partitioning::Maintainer.ensure!(self.class, partition_time(log))
    end

    def partition_time(log)
      self[log.timestamp_column] || Time.current
    end
  end
end
