# Upgrade to 0.6.0

Aggregation runs now key off `period_start` instead of `day`. New hosts get that column from the install migration. Hosts that already ran 0.5.0 copy the upgrade migration and migrate.

```
bin/rails generate recording_studio_logs:migrations
bin/rails db:migrate
```

The upgrade copies each stored `day` to midnight UTC on `period_start`, then drops `day`. Daily summaries that use a `day` date column do not change.

`interval: :daily` still registers. Prefer `period: :day, every: 1`, which is the default.

If you add `period: :hour`, give the summary a datetime `period_column:`. Keep `DailyAggregationJob` for yesterday's daily summaries. Schedule `RecordingStudioLogs::AggregationJob` when you need hour, week, or month buckets, `count_after`, or `include_current`.
