# Adopting RecordingStudioLogs

This gem is the shared partition, retention, and daily-summary path. Each producing gem still owns its table and its insert path. Do not move those rows into recordings, and do not merge unrelated logs into one site-view table.

v1 is daily only. A day is a UTC half-open window. NULL group columns stay as their own group. Rebuilding a day replaces that day's summary rows. Semantics, including cancellation, live in [Log semantics](semantics.md). Existing tables move with [Copy and switch a live log table](cutover.md). The dummy app proves that path on a Downloadable-shaped table. It does not change Downloadable itself.

Work each target in order. Do not register a second writer until the old one is gone.

## Downloadable

`recording_studio_downloadable_download_logs` is not ready to partition in place. Do this in Downloadable, in order:

1. Add `recording_studio_logs` and run its migrations generator.
2. Inspect the live table with `Schema.inspect_table` and `Schema.partition_compatibility`. Expect a failure: the primary key is UUID `id` alone, and rows reference `recording_studio_recordings`.
3. Create a new partitioned table with `Schema.partitioned_log` on `occurred_at`. Recreate the foreign key there.
4. Add `root_recording_id`, backfill it from the recording's root, and add `Schema.root_and_time_index`.
5. Keep IP address and user agent on the raw table. Do not declare them as group columns.
6. Copy, validate counts, and switch writes using the cutover playbook. Keep the current writer until that switch. Registering a second writer would double-count.
7. Register `DownloadLog` with `root_column: :root_recording_id` and a `count` aggregation grouped by root and recording.
8. Include `EnsuresPartition`, call `finalize!`, and schedule the jobs.

The dummy table `legacy_download_logs` is that shape. `test/dummy/test/integration/legacy_download_cutover_test.rb` runs the copy, the root backfill, the count check, and rollback. Per-gem PRs are tested by the owner.

## Embeddable

Embed view logs are a different fact from site views. Do this in Embeddable, in order:

1. Add `recording_studio_logs` and run its migrations generator.
2. Map `viewed_at` as `timestamp_column`. Do not rename production columns in the first cutover unless you also rewrite writers.
3. Treat `parent_recording_id` as the parent snapshot. Add and backfill a root column if owner deletion or rooted metrics need it.
4. Keep the bot flag and request fields off `aggregatable`.
5. Copy and switch the live table. Do not fold embed views into a site-view aggregation.
6. Register one embed-view aggregation. Retire any home-grown daily writer in the same change.

## API

API request logs already have `root_recording_id` and `occurred_at`. Do this in the API gem, in order:

1. Add `recording_studio_logs` and run its migrations generator.
2. Inspect compatibility. `request_id` is indexed and is not unique, so it does not block partitioning by itself.
3. Declare `occurred_at` as the timestamp and `root_recording_id` as the root. Leave remote IP, user agent, and request params out of `aggregatable`.
4. Copy and switch. This gem will not rewrite the live table.
5. Register request-count aggregations that group by root. Point Metrics at those summaries only for `count` and `sum`.

## MCP

MCP already writes `recording_studio_mcp_usage_logs` and `recording_studio_mcp_usage_daily_metrics`. The daily table is unique on metric date, method name, and subject name. It has no root column.

Do this in MCP, in order:

1. Leave the current daily writer running until the switch day.
2. Add `recording_studio_logs` and create a partitioned copy of the raw usage table, plus a Logs summary table that includes a root column if owner deletion matters.
3. Backfill, copy, and validate that Logs totals match `recording_studio_mcp_usage_daily_metrics` for a chosen range.
4. Register one aggregation and retire the old daily writer in the same change. Pointing Logs at the raw rows while that writer still runs would double the counts.

## Webhooks

Do not adopt Logs for webhook deliveries.

Endpoints are recordings. Deliveries are operational rows with retries, next attempt, and deduplication. A summary cannot replace that state. A later count of terminal deliveries can read a real log table. It is not a migration of the delivery row.

## Press kits and press centers

Press kits can register `presskits/press_kit_views` against a site-view log that declares `resource_type` as a filter. Press centers do not have a gem. The dummy app registers `press_centers/press_center_views` so the shape is visible. A future press-centers gem should register that name itself and remove the dummy stand-in from any host that copied it.

Walk through the dummy in [Site views, press kits, and press centers](guides/site-views-press-kits.md).

## What stays out

- No second metrics engine. Logs writes summary tables. Metrics queries them when it is installed. Only `count` and `sum` become timeseries. Do not extend Metrics from this gem.
- No hourly, distinct, or correction rollups.
- No per-customer retention inside one table. One policy per table, overridable in host config.
- No raw log rows on admin screens.
- No automatic delete when a subscription is cancelled. The host calls `delete_for_root`.
