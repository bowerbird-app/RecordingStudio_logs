# Decide retention and aggregation before you add a summary

Read this before a gem keeps a log forever, expires raw rows, or adds a daily summary table. The product owner chooses what the log is for. This gem only applies the registration you give it.

Related: [Log semantics](../semantics.md) (cardinality, UTC days, mixed retention, cancellation), [Create a producing gem log](producing-gem.md), [Aggregate another gem's log](cross-gem-aggregation.md), [Schedule log jobs](scheduling.md).

## Contractual vs non-contractual

That split is a **product decision**. An agent does not classify a log from the table name or from volume.

**Contractual** is a row someone may still be owed. Example: proof that a file was downloaded (`RecordingStudio_downloadable`). Keep the raw row. Register `retention: :indefinite` unless the product owner names a finite window they can defend.

**Non-contractual** is analytics. Example: page views (`RecordingStudio_views`). The useful fact is usually a count over a day, a page, or a workspace. Raw rows can expire after those days have been summarized and marked fresh.

Ask:

1. If we deleted this row next month, would we still be able to prove what happened?
2. Does a chart or admin screen need the raw event, or only a total?
3. Who is the audience: the owner of the file, or an analytics dashboard?

If (1) is yes, it is contractual. Keep it. If the answers are charts and totals, it can be non-contractual, and a summary plus finite retention may be appropriate. If nobody can answer, stop. Do not pick `:indefinite` or `90.days` to unblock a PR.

## Aggregation size (Views as the example)

Each `group_by` column multiplies summary rows. Semantics already says this; the rule for a new table is: **add a dimension only when someone needs to filter or chart by it.**

Views per UTC day is small. Views plus country is still relatively small if country has a few dozen values. Views plus device, browser, OS, country, and similar request fields is nearly the size of the raw log, so it saves little.

Illustration only (not measured from production):

| Grouping | Rough rows per UTC day |
|---|---|
| day only | 1 |
| day + country (~50 values) | ~50 |
| day + 50 workspaces + 200 pages | ~10,000 |
| day + workspace + page + device + browser + OS + country | approaches the raw view count |

`RecordingStudioViews` on `main` does **not** group by device, browser, OS, or country. Its daily summary groups by `root_recording_id`, `recording_id`, `resource_type`, and `page_key` (see [Real examples](#real-examples)). Those four are the dimensions the product already queries. Do not add the rest “so we can chart later.”

## Config that exists today

Names and defaults below are from this gem’s source. Host overrides live in `RecordingStudioLogs.configure`. Do not invent extra register keys.

### `RecordingStudioLogs.register`

Implemented in `LogRegistration` (`lib/recording_studio_logs/log_registration.rb`). Public entry: `RecordingStudioLogs.register` (`lib/recording_studio_logs.rb`).

| Option | Default | What it does |
|---|---|---|
| `model` | required | Class or stable string. A string stays dormant until the class loads (`ModelReference`). |
| `timestamp_column` | required | Event-time column. Must be a safe SQL name (`/[a-z_][a-z0-9_]*/`). |
| `partition_interval` | `:monthly` | `:monthly` or `nil`. Anything else raises. |
| `retention` | `:indefinite` | `:indefinite` or a positive `ActiveSupport::Duration` (`Retention.normalize`). |
| `root_column` | `nil` | Column `delete_for_root` matches. Optional until owner deletion or rooted summaries matter. |
| `owner` | model namespace, or `"Host"` | Same owner may replace the registration. A different owner is rejected. |
| `aggregatable` | `{}` | Columns other gems may `filter` (`:eq`), `group`, or `measure` (`:sum`, `:average`, `:minimum`, `:maximum`). Count does not need a column. |

A host can replace one table’s retention without editing the gem:

```ruby
RecordingStudioLogs.configure do |config|
  config.months_ahead = 2
  config.reconciliation_days = 3
  config.retention_for("DownloadLog", 30.days)
end
```

`months_ahead` (default `2`) is the partition maintenance window. `reconciliation_days` (default `3`) is how many UTC days before today `ReconciliationJob` rebuilds. `retention_for` wins over the gem’s `retention:` (`LogRegistration#retention`). v1 is one policy per table.

### `RecordingStudioLogs.aggregate`

Implemented in `AggregationDefinition` (`lib/recording_studio_logs/aggregation_definition.rb`). Public entry: `RecordingStudioLogs.aggregate`.

| Option | Default | What it does |
|---|---|---|
| `source` | required | The producing log’s model (class or string). |
| `name` | required | `owner/purpose`, matching `\A[a-z0-9_]+/[a-z0-9_]+\z`. |
| `summary_model` | required | Summary ActiveRecord model (class or string). |
| `filter` | `{}` | Equality on columns the producer declared as `filter: [:eq]`. |
| `group_by` | `[]` | Columns the producer declared `group: true`. Do not include the timestamp; day is already the time dimension. |
| `measurements` | `{}` | At least one. `:count` or `{ operation: :column }` for `:sum`, `:average`, `:minimum`, `:maximum`. |
| `interval` | `:daily` | Only `:daily` is accepted. Hourly is rejected. |
| `owner` | first segment of `name` | Same replace/reject-other-owner rule as logs. |

`finalize!` validates loaded aggregations against a registered source. A missing source or summary class stays `dormant?` (`source_model.nil? || summary_model.nil? || log.nil?`). The scheduler skips dormant definitions (`Aggregation::Scheduler#runnable`).

The summary table is a normal migration. It needs `id`, `day`, the group columns, one integer or numeric column per measurement, and timestamps. Unique-index the identity columns with `nulls_not_distinct: true`. `Schema.summary_index` builds that index. Initializers do not create tables.

### Freshness and cleanup

`RetentionCleanupJob` calls `cleanup_retention!` (`Retention::Cleaner`). Finite retention is the only path that tries to drop months or delete rows. `:indefinite` returns immediately for that log.

A day (or a whole month, for a partitioned table) is **fresh** only when every aggregation registered on that log has a `succeeded` run for every UTC day in the window, and each of those successes finished at or after the newest arrival in that window (`AggregationRun.log_fresh?` in `lib/recording_studio_logs/aggregation_run.rb`). Arrival is the later of the event time and `arrived_at` (or `created_at` when that column exists). See the README section “Retention and owner deletion.”

Consequences that follow from that check, not from extra flags:

- **Cleanup only deletes days that have been aggregated.** Non-partitioned cleanup splits expired days into fresh vs waiting and deletes only the fresh set (`Cleaner#delete_rows`). A partitioned month drops only when the whole month is older than the cutoff **and** every day in it is fresh (`Cleaner#release`).
- **A log with no aggregation is never cleaned by this gem.** `log_fresh?` returns `false` when the aggregation list is empty. Expired rows stay. That is why a contractual log with no summary must use `:indefinite` and keep the gem’s own pruner if it has one.
- A consumer registered later, and a dormant consumer, also keep the month: they appear in `aggregations_for` but have no covering success (`test_a_dormant_consumer_keeps_the_month`, `test_a_consumer_registered_before_cleanup_keeps_the_month` in `test/logs_postgres_test.rb`).
- Cleanup takes a lock, then re-reads the newest arrival, so a row that commits while it waits still keeps the window.

### Owner deletion: `delete_for_root`

`RecordingStudioLogs.delete_for_root(root_recording_id:, dry_run: false)` (`Retention::OwnerDeletion`).

It deletes matching raw rows on loaded logs that declared `root_column`, plus summary rows whose `group_by` includes that column. Summaries that omit the root are rebuilt for the affected UTC days so the deleted owner’s counts do not stay in the total. Those names are reported as `unscoped_aggregations`. Cancelling a subscription does not call this. The host decides.

**Dormant aggregations make the delete a no-op.** If any consumer of a rooted log is `dormant?`, `OwnerDeletion` returns an empty report and does not delete (`return report([]) if dormant_consumer?`). `test_a_dormant_consumer_blocks_owner_deletion` shows the raw rows and summaries still there. Passing `dry_run: true` still counts; the live call does not.

### Jobs

This gem ships ActiveJob classes. It does not start Sidekiq or cron (`lib/recording_studio_logs/jobs.rb`). The host enqueues them. Schedule order is in [Schedule log jobs](scheduling.md).

| Job | Default work |
|---|---|
| `DailyAggregationJob` | Rebuilds yesterday UTC (`Time.now.utc.to_date - 1`) for every non-dormant aggregation. Pass a day to rebuild that day. |
| `ReconciliationJob` | Rebuilds each UTC day from `today - reconciliation_days` through yesterday, so a late row is included. |
| `RetentionCleanupJob` | Runs `cleanup_retention!`. `perform(dry_run: true)` previews. |

Also shipped, not retention-specific: `PartitionMaintenanceJob` (previous month through `months_ahead`), `BackfillJob` (one aggregation name, inclusive date range). The same work is `aggregate_day!`, `reconcile!`, `cleanup_retention!`, `maintain_partitions!`, and `backfill!`.

### Admin statuses: “Cleanup waiting” and “Missing table”

Screens are read-only. Labels live in `RecordingStudioLogs::Admin::Status` (`lib/recording_studio_logs/admin/status.rb`).

**Cleanup waiting** is a **log** badge. It is set when retention is not indefinite and the latest cleanup dry-run listed that table (or one of its `table_yyyy_mm` partitions) in `blocked`. Typical cause: expired data that is not fresh yet. Log health picks this up on the next read (`test_log_health_picks_up_cleanup_waiting_on_the_next_read`).

**Missing table** is a **summary** badge. It is set when the aggregation is not dormant but `summary_ready?` is false (the summary model’s table does not exist). A dormant aggregation shows **Waiting** instead. A recorded `failed` run shows **Failed**.

Other log badges: **Waiting** (model not loaded), **Missing month** (a month in the maintenance window is not attached), **OK**. Filter chips also include **Needs attention** (anything that is not OK).

## Checklist for an agent adding an aggregate table

1. **Get the dimensions agreed first.** Write down `filter`, `group_by`, and measurements. If the list includes request fields “just in case,” go back. This is a product decision.
2. **Add the migration, model, and `aggregate` call together.** A registration whose `summary_model` cannot load is dormant. Dormant consumers block retention and make `delete_for_root` a no-op.
3. **Add a rebuild/backfill.** Use `BackfillJob` or `RecordingStudioLogs.backfill!` for the inclusive UTC range that already has raw rows. Daily jobs only cover yesterday plus the reconciliation window.
4. **Pick the retention.** Contractual, no summary: `:indefinite` and the gem’s own pruner. Non-contractual, with a real summary: a positive duration the owner named. Do not set a finite window on a log with no aggregations.
5. **Write tests and an upgrade note.** Cover registration, a rebuild that does not double-count, retention or `:indefinite`, and `delete_for_root` if you declared `root_column`. Hosts need a note for the new migration and any job they must schedule.
6. **Do not flip host defaults.** Leave `months_ahead` and `reconciliation_days` unless the host asked. Do not call `retention_for` from a gem to override another gem’s table.

## Do

- Keep summaries per UTC day. The window is half-open, `[day, next day)` midnight UTC. Jobs, retention, and rebuilds use that same day.
- Keep the root column on the raw log, and include it in `group_by` when owner deletion should drop those summary rows.
- Declare only columns other gems may actually filter, group, or measure.
- Ship one summary table per aggregation. Two consumers can read the same raw rows.
- Rebuild a day with delete-and-insert so a retry does not double-count.

## Do not

- **Do not leave an `aggregate` call without its model.** A missing class is dormant. Cleanup will not drop that log’s expired days. `delete_for_root` becomes a no-op.
- **Do not set a finite retention on a log with no aggregation.** This gem will never mark those days fresh. Use `:indefinite` and keep the gem’s own pruner.
- **Do not add a summary “just in case.”** Extra dimensions approach the raw table. Extra aggregations block cleanup until they succeed.
- **Do not drop or edit a shipped summary migration.** Stop using the aggregation instead: remove the `aggregate` call once hosts have moved, leave the table, and do not rewrite old `schema.rb` history.
- Do not also `group_by` the timestamp.
- Do not put IP address, user agent, session id, or visitor id in `group_by` to fake unique views. v1 has no distinct count.
- Do not hook billing to log deletion. The host calls `delete_for_root`.

## Real examples

### Downloadable: no aggregation, indefinite retention (target)

[RecordingStudio_downloadable PR #25](https://github.com/bowerbird-app/RecordingStudio_downloadable/pull/25) is the target pattern. It is **not merged** as of this writing. Treat the following as the intended shape, not as code already on `main`.

Download logs are contractual: they can prove a file was downloaded. The PR registers the existing table with RecordingStudioLogs and **does not** call `aggregate`. Retention is `:indefinite` because a log with no aggregations is never cleaned by `RetentionCleanupJob`. The gem’s own pruner still deletes. `root_recording_id` stays so `delete_for_root` can match rows. `partition_interval: nil` until a later cutover; the live UUID `id` primary key is not ready to partition in place.

Do not copy a daily download-count summary into that gem to “make retention work.” Finite retention without a covering aggregation does not delete.

### Views: daily summaries on `main`

From `RecordingStudio_views` `main`, `RecordingStudioViews.register_view_log!` in `lib/recording_studio_views.rb`:

- Log model: `RecordingStudioViews::ViewLog`
- `timestamp_column: :occurred_at`
- `retention: 90.days`
- `root_column: :root_recording_id`
- `partition_interval:` `Storage.partition_interval` (`:monthly` if the table is partitioned, otherwise `nil`)
- `aggregatable`: `root_recording_id`, `recording_id`, `resource_type`, `page_key` (each `filter: [:eq], group: true`)
- Aggregation name: `views/page_views`
- Summary model: `RecordingStudioViews::DailyViewSummary`
- `group_by: %i[root_recording_id recording_id resource_type page_key]`
- `measurements: { views: :count }`
- `interval: :daily`
- Owner: `"Recording Studio Views"`

That is a non-contractual page-view log: raw rows may expire after 90 days once those UTC days have succeeded aggregations. The four group columns are the product’s chart keys. Device, browser, OS, and country are not in `aggregatable` and are not in the summary.
