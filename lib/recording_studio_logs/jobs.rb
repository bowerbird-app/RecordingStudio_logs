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

  class AggregationJob < ActiveJob::Base
    queue_as :default

    def perform(now = nil)
      stamp = now.nil? ? Time.now.utc : AggregationRun.coerce_start(now)
      RecordingStudioLogs.aggregate_due!(now: stamp)
    end
  end

  class AggregatePeriodJob < ActiveJob::Base
    queue_as :default

    def self.enqueue(aggregation_name, period_start)
      start = AggregationRun.coerce_start(period_start)
      return unless AggregationRun.reserve_queue(aggregation_name: aggregation_name, period_start: start)

      perform_later(aggregation_name, start.iso8601)
    end

    def perform(aggregation_name, period_start)
      start = AggregationRun.coerce_start(period_start)
      AggregationRun.release_queue!(aggregation_name: aggregation_name, period_start: start)
      RecordingStudioLogs.aggregate_period!(aggregation_name, start)
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
