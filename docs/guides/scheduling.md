# Schedule log jobs

This gem ships ActiveJob classes. It does not start Sidekiq or a cron runner. The host enqueues them.

## Recipe

Pick a UTC window when inserts are quiet, then run this order:

1. `RecordingStudioLogs::PartitionMaintenanceJob` so the previous month through `months_ahead` exist.
2. `RecordingStudioLogs::DailyAggregationJob` after midnight UTC, so yesterday is closed.
3. `RecordingStudioLogs::ReconciliationJob` after that, so a late row from `reconciliation_days` is included.
4. `RecordingStudioLogs::RetentionCleanupJob` last, so a month is never dropped before its summaries finish.

`BackfillJob` is manual. Pass the aggregation name and an inclusive date range.

The same work is `maintain_partitions!`, `aggregate_day!`, `reconcile!`, `backfill!`, and `cleanup_retention!(dry_run: true)` for a preview.

## Timing

Day boundaries are UTC. A job that runs at 00:30 in Los Angeles still belongs to the previous UTC day. Set the schedule in UTC.

Keep `months_ahead` at 2 unless you insert far into the future. `ReconciliationJob` uses `config.reconciliation_days`, default 3.

## Failure

One aggregation failure is stored on that name. A sibling that already succeeded stays. Fix the consumer, then run `BackfillJob` for the failed days. Retention will not drop a month that still lacks a success.
