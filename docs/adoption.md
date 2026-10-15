# Adopting RecordingStudioLogs

This gem is the shared partition, retention, and daily-summary path. Each producing gem still owns its table and its insert path. Do not move those rows into recordings, and do not merge unrelated logs into one site-view table.

v1 is daily only. A day is a UTC half-open window. NULL group columns stay as their own group. Rebuilding a day replaces that day's summary rows. A late row keeps its month until every aggregation for that log has a success finished at or after the row. That includes a consumer registered after the last rebuild, and a consumer whose gem is not loaded. Inserts into a dropped month fail on purpose.

Summaries that omit `root_recording_id` are rebuilt for the affected days when an owner is deleted, so the deleted owner's counts do not stay in the total. `delete_for_root` still reports those names as unscoped. Group by the root column when a summary should drop that owner's rows instead of rebuilding the whole day. A consumer whose model is not loaded blocks the delete.

## Downloadable

`recording_studio_downloadable_download_logs` is not ready to partition in place.

- The primary key is a UUID `id`. A range partition also needs `occurred_at` in the primary key and in every unique index.
- Rows reference `recording_studio_recordings`. Recreate that foreign key as part of a copy-and-switch cutover.
- There is no `root_recording_id`. Add the column and backfill it from the recording's root before summaries or owner deletion can use it.
- IP address and user agent stay on the raw table. Do not declare them as group columns.

Keep the current writer until the cutover. Registering a second writer would double-count.

## Embeddable

Embed view logs are a different fact from site views.

- The parent column is `parent_recording_id`, not a root snapshot.
- The timestamp is `viewed_at`.
- Rows include a bot flag and request fields that should stay off summary group keys.

Do not fold embed views into a site-view aggregation.

## API

API request logs already have `root_recording_id` and `occurred_at`. A later migration can declare those as the root and timestamp. `request_id` is indexed and is not unique. Remote IP, user agent, and request params stay on the raw row. Leave them out of `aggregatable`.

The same manual partition cutover applies: new table, copy, switch writes. This gem will not rewrite the live table.

## MCP

MCP already writes `recording_studio_mcp_usage_logs` and `recording_studio_mcp_usage_daily_metrics`. The daily table is unique on metric date, method name, and subject name. It has no root column.

Leave that writer in place. Pointing Logs at the same raw rows while the current daily writer still runs would double the counts. A later switch can register one aggregation and retire the old writer in the same change.

## Webhooks

Endpoints are recordings. Deliveries are operational rows: retries, next attempt, and deduplication. Do not migrate delivery state into a log summary. A count of terminal deliveries can be a later aggregation over a real log table. It is not a replacement for the delivery row.

## Press kits and press centers

Press kits can register `presskits/press_kit_views` against a site-view log that declares `resource_type` as a filter. Press centers do not have a gem. The dummy app registers `press_centers/press_center_views` so the shape is visible. A future press-centers gem should register that name itself and remove the dummy stand-in from any host that copied it.

## What stays out

- No second metrics engine. Logs writes summary tables. Metrics queries them when it is installed.
- No hourly, distinct, or correction rollups.
- No per-customer retention inside one table. One policy per table, overridable in host config.
- No raw log rows on admin screens.
