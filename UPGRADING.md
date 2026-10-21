# Upgrade to 0.6.0

Aggregation runs now key off `period_start` instead of `day`. Run the migration **before** booting 0.6.0 code. `AggregationRun` reads `period_start`, so an unmigrated host will fail on first use.

```
bin/rails generate recording_studio_logs:migrations
bin/rails db:migrate
```

New hosts still get the original create migration (`day`), then `RenameAggregationRunDayToPeriodStart` copies each stored `day` to midnight UTC on `period_start` and drops `day`. Hosts that already ran 0.5.x take the same upgrade path. Migrating twice is a no-op. Daily summaries that use a `day` date column do not change.

The upgrade briefly takes an `ACCESS EXCLUSIVE` lock on `recording_studio_logs_aggregation_runs` while it rewrites that small table. Summary `day` columns are untouched.

`bin/rails db:rollback` of the rename is safe only while every aggregation is daily. Hour buckets can collide when `period_start` is folded back to a date.

`interval: :daily` still registers. Prefer `period: :day, every: 1`, which is the default.

If you add `period: :hour`, give the summary a datetime `period_column:`. Keep `DailyAggregationJob` for yesterday's daily summaries. Schedule `RecordingStudioLogs::AggregationJob` when you need hour, week, or month buckets, `count_after`, or `include_current`.
