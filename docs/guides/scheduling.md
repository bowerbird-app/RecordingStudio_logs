# Schedule log jobs

This gem ships ActiveJob classes. It does not start Sidekiq or a cron runner. The host enqueues them.

## Recipe

Pick a UTC window when inserts are quiet, then run this order:

1. `RecordingStudioLogs::PartitionMaintenanceJob` so the previous month through `months_ahead` exist.
2. `RecordingStudioLogs::AggregationJob` often enough for your shortest period. An hourly run covers daily summaries after midnight UTC, and hour buckets after each hour ends.
3. `RecordingStudioLogs::DailyAggregationJob` still rebuilds yesterday for daily aggregations. Keep it if that is already on your schedule. It skips hour, week, and month aggregations.
4. `RecordingStudioLogs::ReconciliationJob` after that, so a late row from the last `reconciliation_days` periods is included.
5. `RecordingStudioLogs::RetentionCleanupJob` last, so a month is never dropped before its summaries finish.

`BackfillJob` is manual. Pass the aggregation name and an inclusive range of period starts. `AggregatePeriodJob` rebuilds one period. Async `count:` enqueues it.

The same work is `maintain_partitions!`, `aggregate_due!`, `aggregate_day!`, `reconcile!`, `backfill!`, and `cleanup_retention!(dry_run: true)` for a preview.

## Timing

Period boundaries are UTC. A job that runs at 00:30 in Los Angeles still belongs to the previous UTC day. Set the schedule in UTC.

`count_after:` waits after a period ends before `AggregationJob` counts it. `include_current:` also refreshes the open period.

Keep `months_ahead` at 2 unless you insert far into the future. `ReconciliationJob` uses `config.reconciliation_days`, default 3. Daily aggregations still treat that as days. Other periods treat it as a count of periods.

## Failure

One aggregation failure is stored on that name. A sibling that already succeeded stays. Fix the consumer, then run `BackfillJob` for the failed periods. Retention will not drop a month that still lacks a success.
