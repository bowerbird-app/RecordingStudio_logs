# Upgrade to 0.7.3

No API or migration change. Dummy and development GitHub pins move to Recording Studio `v6.3.0`, Flatpack `v0.1.341`, Metrics `v0.7.2`, Accessible `v0.24.0`, Cache `v0.6.2`, and Root Switchable `v0.11.3`. Admin stays `v2.7.0`. Trashable stays `v0.12.0`. Gemspec floors are unchanged. The engine no longer ships `RecordingStudioLogs::ApplicationController`. Lockfiles bump `crass` to 1.0.8 or later, and the dummy lockfile bumps `net-ssh` to 7.3.5 or later.

# Upgrade to 0.7.2

No API or migration change. Docs match the 0.7.1 Metrics range. Dummy leftover files and tracked SimpleCov output are gone. Rack in both lockfiles is 3.2.8 or later.

# Upgrade to 0.7.1

`recording_studio` is `>= 6.1.0`. `recording_studio_metrics` is `>= 0.6.1, < 1.0` (Metrics 0.7.x is OK; dummy GitHub tag `v0.7.0`). Complete the 0.7.0 notes first if you are still on 0.6.x.

# Upgrade to 0.7.0

Logs no longer patches RecordingStudioMetrics. Daily count and sum summaries register through the public Metrics API. Pin `recording_studio_metrics` to `>= 0.6.1, < 1.0` (GitHub tag `v0.6.1` or later 0.6/0.7).

1. No migrations in this gem.
2. Registrations pass `bucket_timezone: "UTC"`, `fill_gaps: true`, `scope_attribute` set to the log's root column, and `scope_value: :root_recording_id`. Empty UTC days come back as zeros. Pass a `root_recording:` on the Metrics context. Do not pass `workspace_id:` for Logs series: that is the workspace/recordable id, not the root recording id.
3. The caller's timezone is ignored for Logs series. Buckets stay on the stored UTC day (`bucket_timezone: "UTC"`).
4. A bad timezone or a non-time `start_at` still raises `RecordingStudioMetrics::Errors::InvalidDateRange`. That comes from Metrics, not a Logs prepend.
5. `group_by` on a Logs-published timeseries raises `RecordingStudioMetrics::Errors::InvalidGroupBy`. Metrics registered by other gems keep the dimensions they declared.
6. `config/recording_studio_logs.yml` is still optional. A missing file is ignored. A nil config path is skipped the same way. Invalid YAML raises. Do not rely on Logs swallowing a bad config file.
7. The engine no longer ships a template home route, Tailwind `@source` installer, or `extend_model` / `extend_controller` class_eval hooks.

If you are still on `0.6.0` or older, complete that release's notes first.

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
