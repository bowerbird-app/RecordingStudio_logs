# Migration notes

## Aggregation and maintenance runs

Generate the runs migration and migrate before the first aggregation or retention job:

```
bin/rails generate recording_studio_logs:migrations
bin/rails db:migrate
```

That creates `recording_studio_logs_aggregation_runs` and `recording_studio_logs_maintenance_runs`. From 0.6.0 the run identity is `(aggregation_name, period_start)`. Hosts that already have `day` run the upgrade migration. Producing gems ship the log table. Consuming gems ship the summary table. Initializers do not create those tables.

## Existing production tables

Do not auto-repartition a table that is already in production. PostgreSQL requires the partition key in the primary key and in every unique index, and foreign keys have to be recreated. Use `Schema.inspect_table` and `Schema.partition_compatibility`, then follow [Copy and switch a live log table](cutover.md). New partitioned tables use a primary key of `(id, occurred_at)` with the same UUID `id`.

## Arrival time

`Schema.partitioned_log` adds `arrived_at`, a non-null timestamp that defaults to `CURRENT_TIMESTAMP`. Retention treats that stamp as the row's arrival, including when the table has no `created_at`. A partitioned table created before this column existed should add it:

```
add_column :your_logs, :arrived_at, :datetime, null: false, default: -> { "CURRENT_TIMESTAMP" }
```

## UTC days

A default summary day is a UTC half-open window: from midnight UTC inclusive to the next midnight exclusive. Hour, week, and month periods use the same half-open rule on their period start. Jobs and retention use that same start. Do not also group by the timestamp column.

## PostgreSQL 15 or newer

Summary identity indexes are `NULLS NOT DISTINCT`. Two rows that match on the group columns, including NULL groups, are the same group. That index clause requires PostgreSQL 15 or newer.

## schema.rb dumps parent tables only

`schema.rb` records the partitioned parent and its primary key. It does not record child partitions. The dummy schema shows this for `site_views` and `sample_downloads`: `primary_key: ["id", "occurred_at"]` and `options: "PARTITION BY RANGE (occurred_at)"`. `PartitionMaintenanceJob` and `EnsuresPartition` create the month tables at runtime. A host that loads `schema.rb` still needs a partition maintenance run before inserts into the current month.
