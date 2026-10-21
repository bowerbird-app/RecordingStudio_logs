# frozen_string_literal: true

require "active_record"
require "active_job"
require "recording_studio"
require "recording_studio_logs/version"
require "recording_studio_logs/engine"
require "recording_studio_logs/errors"
require "recording_studio_logs/configuration"
require "recording_studio_logs/model_reference"
require "recording_studio_logs/column_contract"
require "recording_studio_logs/measurement"
require "recording_studio_logs/retention"
require "recording_studio_logs/log_registration"
require "recording_studio_logs/aggregation/period_alignment"
require "recording_studio_logs/aggregation/period_windows"
require "recording_studio_logs/aggregation/period"
require "recording_studio_logs/aggregation/period_options"
require "recording_studio_logs/aggregation/definition_period"
require "recording_studio_logs/aggregation_definition"
require "recording_studio_logs/registry"
require "recording_studio_logs/lock"
require "recording_studio_logs/schema/aggregation_runs_upgrade"
require "recording_studio_logs/schema"
require "recording_studio_logs/schema/inspection"
require "recording_studio_logs/cutover"
require "recording_studio_logs/aggregation_run"

require "recording_studio_logs/maintenance_run"
require "recording_studio_logs/partitioning/names"
require "recording_studio_logs/partitioning/catalog"
require "recording_studio_logs/partitioning/window"
require "recording_studio_logs/partitioning/detector"
require "recording_studio_logs/partitioning/table_stats"
require "recording_studio_logs/partitioning/maintainer"

require "recording_studio_logs/retention/window_rows"
require "recording_studio_logs/retention/raw_rows"
require "recording_studio_logs/retention/cleaner_context"
require "recording_studio_logs/retention/window_cleaner"
require "recording_studio_logs/retention/day_cleaner"
require "recording_studio_logs/retention/cleaner"
require "recording_studio_logs/retention/owner_deletion"
require "recording_studio_logs/aggregation/count_recounter"
require "recording_studio_logs/aggregation/count_trigger"
require "recording_studio_logs/aggregation/statement"
require "recording_studio_logs/aggregation/runner"
require "recording_studio_logs/aggregation/scheduler"
require "recording_studio_logs/metrics_boundary"
require "recording_studio_logs/metrics_bridge"
require "recording_studio_logs/ensures_partition"
require "recording_studio_logs/jobs"
require "recording_studio_logs/admin/status"
require "recording_studio_logs/admin/catalog"
require "recording_studio_logs/admin"

module RecordingStudioLogs
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
      configuration
    end

    def registry
      @registry ||= Registry.new
    end

    def register(...)
      registry.register_log(...)
    end

    def aggregate(...)
      registry.register_aggregation(...)
    end

    def logs
      registry.logs
    end

    def aggregations
      registry.aggregations
    end

    def finalize!
      registry.finalize!
      MetricsBridge.register!
    end

    def reset!
      registry.reset!
    end

    def missing_partitions(...)
      Partitioning::Detector.missing(...)
    end

    def maintain_partitions!
      Partitioning::Maintainer.call
    end

    def ensure_partition!(model, time)
      Partitioning::Maintainer.ensure!(model, time)
    end

    def aggregate_day!(day)
      Aggregation::Scheduler.aggregate_day(day)
    end

    def aggregate_due!(now: Time.now.utc)
      Aggregation::Scheduler.aggregate_due(now)
    end

    def aggregate_period!(name, period_start)
      Aggregation::Scheduler.aggregate_period(name, period_start)
    end

    def backfill!(name, from:, to:)
      Aggregation::Scheduler.backfill(name, from: from, to: to)
    end

    def reconcile!(now: Time.now.utc, today: nil)
      Aggregation::Scheduler.reconcile(now: now, today: today)
    end

    def cleanup_retention!(dry_run: false)
      Retention::Cleaner.call(dry_run: dry_run)
    end

    def delete_for_root(root_recording_id:, dry_run: false)
      Retention::OwnerDeletion.call(root_recording_id: root_recording_id, dry_run: dry_run)
    end
  end
end
