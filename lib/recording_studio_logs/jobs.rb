# frozen_string_literal: true

module RecordingStudioLogs
  class PartitionMaintenanceJob < ActiveJob::Base
    queue_as :default

    def perform
      RecordingStudioLogs.maintain_partitions!
    end
  end

  class RetentionCleanupJob < ActiveJob::Base
    queue_as :default

    def perform(dry_run: false)
      RecordingStudioLogs.cleanup_retention!(dry_run: dry_run)
    end
  end

  class DailyAggregationJob < ActiveJob::Base
    queue_as :default

    def perform(day = nil)
      date = day.present? ? Date.parse(day.to_s) : Time.now.utc.to_date - 1
      RecordingStudioLogs.aggregate_day!(date)
    end
  end

  class BackfillJob < ActiveJob::Base
    queue_as :default

    def perform(aggregation_name, from, to)
      RecordingStudioLogs.backfill!(aggregation_name, from: from, to: to)
    end
  end

  class ReconciliationJob < ActiveJob::Base
    queue_as :default

    def perform
      RecordingStudioLogs.reconcile!
    end
  end
end
