# RecordingStudioLogs

Shared PostgreSQL logging for Recording Studio gems. A producing gem stores high-volume rows in its own table. Other gems register daily summaries over the columns that producer allows. RecordingStudio_metrics stays the query API. This gem does not depend on it.

Logs are exhaust. They are not recordings, and they are not `log_event!` history.

## Register a log

The producing gem declares the table, the timestamp, retention, and the columns other gems may use.

```ruby
RecordingStudioLogs.register(
  model: "DownloadLog",
  timestamp_column: :occurred_at,
  retention: 90.days,
  root_column: :root_recording_id,
  partition_interval: :monthly,
  aggregatable: {
    root_recording_id: { filter: [:eq], group: true },
    recording_id: { filter: [:eq], group: true },
    duration_ms: { measurements: [:sum] }
  }
)
```

`model:` may be a class or a stable string. A string stays dormant until that gem is loaded, so boot order does not matter. The same owner can register that model or aggregation name again, and the new definition replaces the old one. A different owner is rejected.

`partition_interval:` is `:monthly` or `nil`. New partitioned tables use a primary key of `(id, occurred_at)` and the same UUID `id`. Create them with `RecordingStudioLogs::Schema.partitioned_log`. Call `Schema.root_and_time_index` when you look up by root and time. Include `RecordingStudioLogs::EnsuresPartition` on the model so an insert into a missing month creates that month first.

A host can override one table's retention without editing the gem:

```ruby
RecordingStudioLogs.configure do |config|
  config.months_ahead = 2
  config.reconciliation_days = 3
  config.retention_for("DownloadLog", 30.days)
end
```

`:indefinite` is the retention that never deletes. v1 has one policy per table.

## Aggregations

A consumer registers a daily summary. The name is namespaced, `owner/purpose`.

```ruby
RecordingStudioLogs.aggregate(
  source: "DownloadLog",
  name: "presskits/press_kit_views",
  summary_model: "PressKitViewSummary",
  filter: { resource_type: "PressKit" },
  group_by: %i[root_recording_id recording_id],
  measurements: { views: :count, total_duration: { sum: :duration_ms } }
)
```

The day is the time dimension. It is a UTC half-open window, `[day, next day)`. Do not also `group_by` the timestamp. Filters are equality on declared columns. `group_by` and measurements must be declared by the producer. Count does not need a column. Sum, average, minimum, and maximum do.

Each aggregation has its own summary table and its own migration. Initializers do not create tables. The summary needs `id`, `day`, the group columns, one integer or numeric column per measurement, and timestamps. Unique index the identity columns with `nulls_not_distinct: true`, so SQL NULL is its own group. `RecordingStudioLogs::Schema.summary_index` builds that index.

Two aggregations can read the same raw rows. Rebuilding a day deletes that day's summary rows and inserts them again, so a rerun does not double-count. One failure is recorded on that aggregation and does not roll back a sibling that already finished.

Hourly rollups, distinct counts, and event corrections are out of this version.

## Build the tables

Copy the runs migration into the host, then migrate:

```bash
bin/rails generate recording_studio_logs:migrations
bin/rails db:migrate
```

That adds `recording_studio_logs_aggregation_runs` and `recording_studio_logs_maintenance_runs`. Producing and consuming gems ship their own log and summary migrations. See `docs/MIGRATION_NOTES.md` for UTC days, PostgreSQL 15, and what `schema.rb` dumps. See `docs/cutover.md` for a live table. Guides for a producing gem, cross-gem summaries, jobs, and the site-view example live in `docs/guides/`.

Call `RecordingStudioLogs.finalize!` at the end of the initializer that registers logs. The engine also finalizes on boot.

## Querying

Summary tables are ordinary ActiveRecord models. Read them directly when metrics is not installed.

When `RecordingStudioMetrics` is loaded, a summary that is ready, groups by the log's root column, and has a count or sum is registered as a timeseries. Only count and sum are published. Do not extend Metrics from this gem. Average, minimum, and maximum stay on the summary table. The metric sums the stored daily column and is scoped to the root recording's id. The series is a fresh UTC-day rollup. A day with no summary stays empty. The resource name is the aggregation name with `/` replaced by `_`. This gem still writes summaries when metrics is absent. A bad timezone or a bad `start_at` raises a metrics input error. `group_by` on a Logs-published timeseries also raises a metrics input error. Metrics registered by other gems keep the `group_by` dimensions they declared.

## Retention and owner deletion

`RecordingStudioLogs.cleanup_retention!` drops a month only when the whole month is older than the policy and every aggregation for that log has a succeeded run for every UTC day in the month. A log with no aggregations is not fresh, so the month stays. A consumer registered later, and one whose model is not loaded, also keep the month. Each success must have finished at or after the newest arrival in the month. Arrival is the later of the event time and `arrived_at`. Tables created with `Schema.partitioned_log` stamp `arrived_at` in the database at insert. `created_at` counts too, when the table has it. The drop and a non-partitioned delete take a lock that blocks inserts, then read the newest row again before removing anything. A row committed while that lock is waiting is still there when cleanup continues. Non-partitioned cleanup deletes only the UTC days that have a covering success. A day that still has a row before the cutoff, and has no success, stays.

`RecordingStudioLogs.delete_for_root(root_recording_id:)` deletes matching raw rows and the summary rows whose `group_by` includes that root column. It does this in one transaction, under the same per-day advisory locks the rebuild uses. Summaries that do not group by the root are rebuilt for the affected UTC days, so the deleted owner's counts do not stay in the total. Those names are still reported as `unscoped_aggregations`. A consumer whose model is not loaded blocks the delete. Pass `dry_run: true` to count without deleting. Cancelling a subscription does not call this. The host decides.

## Jobs

The host schedules these ActiveJob classes. This gem does not start Sidekiq or a cron runner.

- `RecordingStudioLogs::PartitionMaintenanceJob` keeps the previous month through `months_ahead`.
- `RecordingStudioLogs::DailyAggregationJob` rebuilds yesterday (UTC) for every ready aggregation.
- `RecordingStudioLogs::ReconciliationJob` rebuilds the last `reconciliation_days` before today, so a late row is included.
- `RecordingStudioLogs::BackfillJob` rebuilds one aggregation across an inclusive date range.
- `RecordingStudioLogs::RetentionCleanupJob` runs retention. `perform(dry_run: true)` previews.

The same entry points exist as `RecordingStudioLogs.maintain_partitions!`, `aggregate_day!`, `reconcile!`, `backfill!`, and `cleanup_retention!`.

## Moving an existing table

Do not auto-repartition a table that is already in production. Inspect the table with `Schema.inspect_table` and `Schema.partition_compatibility`. Copy with `Cutover.copy` and `Cutover.validate`. Switch writes in a short `ACCESS EXCLUSIVE` window. See [Copy and switch a live log table](docs/cutover.md) and [Adopting RecordingStudioLogs](docs/adoption.md).

`RecordingStudioLogs.missing_partitions` lists months in the maintenance window that are not attached.

## Admin

Screens register only when `RecordingStudioAdmin` is loaded. They are read-only, granted through Accessible on an admin root, and they do not show raw log rows. The section key is `logs`. The screens are `log_health`, `log_detail`, `summaries`, and `summary_detail`. Log health shows table name, approximate rows, storage, and maintenance status. The detail screen shows configuration. See [Log admin screens](docs/guides/admin-screens.md).

## Dummy app

The dummy app is a host, not a product. It registers a partitioned site-view log, daily press-kit and press-center summaries over those same rows, and an indefinite download-shaped log. It also has `legacy_download_logs`, an unpartitioned Downloadable-shaped table used only to prove copy-and-switch. Press centers do not have a gem. This dummy is that consumer. Admin is not mounted here: `recording_studio_admin` 2.3.2 needs Flatpack `~> 0.1.207`, and this dummy stays on the pin below. Do not change that pin in this gem.

Dummy pins:

- dummy GitHub tag `v4.7.0` for Recording Studio
- dummy GitHub tag `v0.18.0` for Accessible
- dummy GitHub tag `v0.11.0` for Trashable
- dummy GitHub tag `v0.9.0` for Root Switchable
- dummy GitHub tag `v0.1.196` for Flatpack

Boot instructions live in `.cursor/install.sh` and `test/dummy/README.md`. Sign in at `/users/sign_in` with `admin@admin.com` / `Password`.
