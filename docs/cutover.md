# Copy and switch a live log table

Do not `ALTER TABLE ... PARTITION BY` a table that already has production rows. PostgreSQL needs the partition key in the primary key and in every unique index. Foreign keys have to be rebuilt.

This playbook uses `RecordingStudioLogs::Schema.inspect_table`, `Schema.partition_compatibility`, `Cutover.copy`, and `Cutover.validate`. The dummy app runs the same helpers in `test/dummy/test/integration/legacy_download_cutover_test.rb`.

## Risks

- The rename switch takes `ACCESS EXCLUSIVE` on both names. Writers wait. Plan a short window.
- `Cutover.copy` reads the source with a normal `SELECT`. Concurrent inserts after the copy starts are missing until you copy again or stop writes.
- A unique index that omits the timestamp cannot exist on the new parent. Fix that in the new table. Do not try to keep it.
- An inbound foreign key that pointed at the old primary key of `id` alone cannot point at `(id, occurred_at)` without a matching unique constraint. Recreate those keys on purpose, or drop them.
- Rollback is a second rename. It only works if you kept the old table and stopped the new writer.

## 1. Inspect

```ruby
inspection = RecordingStudioLogs::Schema.inspect_table("download_logs")
report = RecordingStudioLogs::Schema.partition_compatibility(
  "download_logs",
  timestamp_column: :occurred_at
)
```

`report.compatible` is true only when the primary key and every unique index already include the timestamp, and inbound foreign keys can follow that key. Downloadable-shaped tables fail this check. That is expected. You copy, you do not convert in place.

## 2. Create the new table

Create `download_logs_partitioned` with `Schema.partitioned_log`. Use a primary key of `(id, occurred_at)`. Add the same payload columns. Add `root_recording_id` if the old table lacks it. Call `Schema.root_and_time_index` for owner lookups.

```ruby
RecordingStudioLogs::Schema.partitioned_log(:download_logs_partitioned, timestamp_column: :occurred_at) do |table|
  table.uuid :root_recording_id
  table.uuid :recording_id
  table.string :ip_address
  table.string :user_agent
  table.timestamps
end
RecordingStudioLogs::Schema.root_and_time_index(
  :download_logs_partitioned,
  root_column: :root_recording_id,
  timestamp_column: :occurred_at
)
```

Attach months that cover `MIN(occurred_at)` through `months_ahead`. `EnsuresPartition` can create a missing month on insert. Maintenance should still create the window first.

## 3. Add and backfill a root column

```ruby
RecordingStudioLogs::Cutover.add_root_column("download_logs")
RecordingStudioLogs::Cutover.backfill_root("download_logs")
```

`backfill_root` copies `recording_studio_recordings.root_recording_id` for rows whose `recording_id` matches. Rows with no recording stay NULL. Summaries that group by root will treat NULL as its own group.

## 4. Copy and validate

Stop or pause the old writer if you need an exact match. Then:

```ruby
columns = %i[id occurred_at recording_id ip_address user_agent root_recording_id created_at updated_at]
RecordingStudioLogs::Cutover.copy(from: "download_logs", to: "download_logs_partitioned", columns: columns)
check = RecordingStudioLogs::Cutover.validate(from: "download_logs", to: "download_logs_partitioned")
raise "copy mismatch" unless check.matched?
```

`copy` uses `INSERT ... SELECT ... ON CONFLICT DO NOTHING`, so a retry does not duplicate primary keys. It still skips rows that landed only on the destination.

Compare the counts you care about, including one aggregation over the source versus the destination, before you switch.

## 5. Switch writes

In one transaction:

1. Lock both tables with `ACCESS EXCLUSIVE`.
2. Rename `download_logs` to `download_logs_old`.
3. Rename `download_logs_partitioned` to `download_logs`.
4. Recreate outbound foreign keys on the new name.
5. Point the ActiveRecord model at the partitioned shape, `(id, occurred_at)`, and include `EnsuresPartition`.

Keep the old table until retention and a later cleanup job prove you do not need it.

## 6. Rollback

If the new writer is wrong and the old table is intact:

1. Stop the new writer.
2. Lock both names with `ACCESS EXCLUSIVE`.
3. Rename the new table aside.
4. Rename `download_logs_old` back to `download_logs`.
5. Restore the old model primary key.

Rows inserted only on the new table during the failed window are not on the old table. Copy them back first if you must keep them.

Do not drop the old table in the same deploy as the switch.
