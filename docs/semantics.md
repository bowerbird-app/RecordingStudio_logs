# Log semantics

This page explains how counts stay honest. The default is one UTC day at a time. You can also bucket by hour, week, or month. It does not correct events, count distinct visitors, or follow a resource after you move it.

## Cardinality

Each `group_by` column multiplies summary rows. A period with 10 workspaces and 1,000 pages is about 10,000 groups when you group by workspace and page. Add session id, IP address, or user agent and the summary approaches the raw table.

Group by the owner and the resource people already look up. Filter on type. Leave request fields on the raw row.

## Duplicates

Two writers on the same facts double the count. Keep one insert path until cutover, then switch it.

Rebuilding a period deletes that period's summary rows and inserts them again. A second successful run of the same period does not add a second copy.

Registering the same aggregation name from a second owner is rejected. The same owner can replace the definition.

## Unique views, page views, and sessions

A raw row is one observed event. A `count` measurement is how many of those rows match the filter. That is a page view, a download, or a request. It is not a unique visitor.

Unique visitors need a distinct count. v1 does not expose distinct. Do not group by visitor or session to fake it. Those keys explode the summary and still miss the same person on two days.

A session is a product rule, not a log default. Store a session id only when you query raw rows for debugging. Do not put it in `group_by`.

## Event corrections

There is no correction table and no negative row. If a fact was wrong, delete or replace the raw row and rebuild that period. If you cannot change the raw row, the summary stays wrong.

Average, minimum, and maximum stay on the summary table. They are not timeseries metrics. See [Querying](../README.md#querying).

## Late events

A row keeps the month of its event time. Arrival is the later of that time and `arrived_at`. `Schema.partitioned_log` stamps `arrived_at` in the database.

`ReconciliationJob` rebuilds the last `reconciliation_days` periods before now. Daily aggregations still treat that integer as days. A row that arrives after the last success for its month blocks retention until a later success covers it. Cleanup takes a lock, then reads the newest arrival again, so a row that commits while it waits still keeps the month. Raw rows stay until every covering period is closed and counted.

## Parent and root changes

The raw row stores the parent or root you wrote at insert time. Moving a page or changing a recording's root does not rewrite old log rows. Summaries that group by that snapshot keep the old owner until you update the raw rows and rebuild those periods.

`delete_for_root` deletes rows whose stored root column matches. It does not chase a resource to a new root.

## UTC and reporting time zones

A default summary day is a UTC half-open window, from midnight UTC up to the next midnight. Hour buckets align to UTC midnight. Weeks start on Monday. Months align to January. Jobs, retention, and rebuilds use the same period start.

Metrics may accept a reporting time zone on execute. That zone does not regroup stored days. A view at 22:00 in Los Angeles on 13 October still sits on 14 October UTC. Empty days stay empty. Do not also `group_by` the timestamp. Metrics still publish only default daily summaries.

## Mixed retention

One policy applies to one table. Different tables may keep different windows. A host override, `config.retention_for("ModelName", duration)`, replaces the gem default for that table. `:indefinite` never drops rows.

Do not put two retention windows in one table. If download logs must last years and request logs must last weeks, they are two tables.

## Subscription cancellation

Cancelling a subscription does not delete logs. This gem never hooks billing.

The host decides. Call `RecordingStudioLogs.delete_for_root(root_recording_id:)` when that owner's rows should go. Pass `dry_run: true` to count first. A consumer whose model is not loaded blocks the delete.
