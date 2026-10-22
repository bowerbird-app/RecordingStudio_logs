# RecordingStudioLogs

Shared PostgreSQL logging for Recording Studio gems. A producing gem stores high-volume rows in its own table. Other gems register summaries over the columns that producer allows, with configurable periods (daily by default). RecordingStudio_metrics stays the query API (`~> 0.6.1`). Summaries still write when Metrics is not loaded.

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

A consumer registers a summary. The name is namespaced, `owner/purpose`. The default bucket is one UTC day.

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

The period is the time dimension. A UTC half-open window. Do not also `group_by` the timestamp. Filters are equality on declared columns. `group_by` and measurements must be declared by the producer. Count does not need a column. Sum, average, minimum, and maximum do.

`period:` is `:hour`, `:day`, `:week`, or `:month`. `every:` is a positive integer, default `1`. Hours, days, and weeks count from a fixed UTC epoch. Weeks start on Monday. Months align to January, so `every: 3` is Jan/Apr/Jul/Oct. `interval: :daily` still means `period: :day`.

`period_column:` is the summary column that stores the period start. The default is `:day`, a date, so existing daily tables stay as they are. Hour periods need a datetime column.

`count:` is `:scheduled` by default. `:sync` rebuilds that row's period after a model save in the same request. `:async` enqueues `AggregatePeriodJob` for that period and collapses duplicate enqueues with the run row. Both rebuild the whole period. `insert_all` does not fire those hooks. The scheduled job is the safety net.

`count_after:` waits after a period ends before the scheduled path counts it. `include_current:` also refreshes the open period.

Each aggregation has its own summary table and its own migration. Initializers do not create tables. The summary needs `id`, the period column, the group columns, one integer or numeric column per measurement, and timestamps. Unique index the identity columns with `nulls_not_distinct: true`, so SQL NULL is its own group. `RecordingStudioLogs::Schema.summary_index` builds that index.

Two aggregations can read the same raw rows. Rebuilding a period deletes that period's summary rows and inserts them again, so a rerun does not double-count. One failure is recorded on that aggregation and does not roll back a sibling that already finished.

Distinct counts and event corrections are out of this version.

## Build the tables

Copy the runs migration into the host, then migrate:

```bash
bin/rails generate recording_studio_logs:migrations
bin/rails db:migrate
```

That adds `recording_studio_logs_aggregation_runs` and `recording_studio_logs_maintenance_runs`. Producing and consuming gems ship their own log and summary migrations. See `docs/MIGRATION_NOTES.md` for UTC days, PostgreSQL 15, and what `schema.rb` dumps. See `docs/cutover.md` for a live table. Guides for a producing gem, cross-gem summaries, jobs, and the site-view example live in `docs/guides/`. Before you add retention or a summary table, read [Decide retention and aggregation before you add a summary](docs/guides/data-retention-and-aggregation.md).

Call `RecordingStudioLogs.finalize!` at the end of the initializer that registers logs. The engine also finalizes on boot.

## Querying

Summary tables are ordinary ActiveRecord models. Read them directly when metrics is not installed.

When `RecordingStudioMetrics` is loaded, a summary that is ready, groups by the log's root column, and has a count or sum is registered as a timeseries through the public Metrics `register` API. Only count and sum are published. Do not extend Metrics from this gem. Average, minimum, and maximum stay on the summary table. The metric sums the stored daily column and is scoped with `scope_attribute` set to the log's root column and `scope_value: :root_recording_id`. Pass `root_recording:` on the Metrics context. The series is a fresh UTC-day rollup (`bucket_timezone: "UTC"`, `fill_gaps: true`). Empty days come back as zeros. The caller's timezone is ignored. The resource name is the aggregation name with `/` replaced by `_`. This gem still writes summaries when metrics is absent. A bad timezone or a bad `start_at` raises a metrics input error. `group_by` on a Logs-published timeseries raises `InvalidGroupBy`. Metrics registered by other gems keep the `group_by` dimensions they declared. Needs Metrics `~> 0.6.1`.

## Retention and owner deletion

With no product decision, register `retention: :indefinite` and do not add an aggregate. That is the register default and the org default for a gem that is ready for RS_Logs. Finite retention plus a summary only when the owner names both (`RecordingStudio_views` is the exception). Contractual logs stay on the raw row. Analytics logs may expire after they have been summarized. That split is a product decision. The checklist, every register and aggregate option, and the Views / Downloadable examples are in [Decide retention and aggregation before you add a summary](docs/guides/data-retention-and-aggregation.md).

`RecordingStudioLogs.cleanup_retention!` drops a month only when the whole month is older than the policy and every aggregation for that log has a succeeded run for every period that overlaps the month. A log with no aggregations is not fresh, so the month stays. A consumer registered later, and one whose model is not loaded, also keep the month. Each success must have finished at or after the newest arrival in the month. Arrival is the later of the event time and `arrived_at`. Tables created with `Schema.partitioned_log` stamp `arrived_at` in the database at insert. `created_at` counts too, when the table has it. The drop and a non-partitioned delete take a lock that blocks inserts, then read the newest row again before removing anything. A row committed while that lock is waiting is still there when cleanup continues. Non-partitioned cleanup deletes only rows whose covering period is closed and counted. A period that still has a row before the cutoff, and has no success, stays.

`RecordingStudioLogs.delete_for_root(root_recording_id:)` deletes matching raw rows and the summary rows whose `group_by` includes that root column. It does this in one transaction, under the same per-period advisory locks the rebuild uses. Summaries that do not group by the root are rebuilt for the affected period starts, so the deleted owner's counts do not stay in the total. Those names are still reported as `unscoped_aggregations`. A consumer whose model is not loaded blocks the delete. Pass `dry_run: true` to count without deleting. Cancelling a subscription does not call this. The host decides.

## Jobs

The host schedules these ActiveJob classes. This gem does not start Sidekiq or a cron runner.

- `RecordingStudioLogs::PartitionMaintenanceJob` keeps the previous month through `months_ahead`.
- `RecordingStudioLogs::DailyAggregationJob` rebuilds yesterday (UTC) for every ready daily aggregation.
- `RecordingStudioLogs::AggregationJob` rebuilds every aggregation whose period has closed, plus `count_after`, and the current period when `include_current` is set. Run this often if you use hour, week, or month buckets.
- `RecordingStudioLogs::AggregatePeriodJob` rebuilds one period of one aggregation. Async count enqueues it.
- `RecordingStudioLogs::ReconciliationJob` rebuilds the last `reconciliation_days` periods before now, so a late row is included. Daily aggregations still treat that integer as days.
- `RecordingStudioLogs::BackfillJob` rebuilds one aggregation across an inclusive range of period starts.
- `RecordingStudioLogs::RetentionCleanupJob` runs retention. `perform(dry_run: true)` previews.

The same entry points exist as `RecordingStudioLogs.maintain_partitions!`, `aggregate_day!`, `aggregate_due!`, `aggregate_period!`, `reconcile!`, `backfill!`, and `cleanup_retention!`.

## Moving an existing table

Do not auto-repartition a table that is already in production. Inspect the table with `Schema.inspect_table` and `Schema.partition_compatibility`. Copy with `Cutover.copy` and `Cutover.validate`. Switch writes in a short `ACCESS EXCLUSIVE` window. See [Copy and switch a live log table](docs/cutover.md) and [Adopting RecordingStudioLogs](docs/adoption.md).

`RecordingStudioLogs.missing_partitions` lists months in the maintenance window that are not attached.

## Admin

Screens register only when `RecordingStudioAdmin` is loaded. They are read-only, granted through Accessible on an admin root, and they do not show raw log rows. The section key is `logs`. The screens are `log_health`, `log_detail`, `summaries`, and `summary_detail`. Log health shows table name, approximate rows, storage, and maintenance status. A Status filter and Needs attention widget link keep the list in step with the count. The detail screen shows configuration. See [Log admin screens](docs/guides/admin-screens.md).

## Dummy app

The dummy app is a host, not a product. It registers a partitioned site-view log, daily press-kit and press-center summaries over those same rows, and an indefinite download-shaped log. It also has `legacy_download_logs`, an unpartitioned Downloadable-shaped table used only to prove copy-and-switch. Press centers do not have a gem. This dummy is that consumer. Admin is not mounted here: `recording_studio_admin` 2.3.2 needs Flatpack `~> 0.1.207`, and this dummy stays on the pin below. Do not change that pin in this gem.

Dummy pins:

- dummy GitHub tag `v4.7.0` for Recording Studio
- dummy GitHub tag `v0.18.0` for Accessible
- dummy GitHub tag `v0.11.0` for Trashable
- dummy GitHub tag `v0.9.0` for Root Switchable
- dummy GitHub tag `v0.6.1` for Metrics
- dummy GitHub tag `v0.1.196` for Flatpack

Boot instructions live in `.cursor/install.sh` and `test/dummy/README.md`. Sign in at `/users/sign_in` with `admin@admin.com` / `Password`.
