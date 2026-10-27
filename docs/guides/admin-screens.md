# Log admin screens

Screens register only when `RecordingStudioAdmin` is loaded. They are read-only. Accessible on an admin root grants them. They never show raw log rows.

The dummy app does not mount Admin. Gem tests load Admin `v2.7.0` and assert screen definitions and catalog queries. Open a host that mounts Admin to see the screens in a browser.

## What staff see

The Logs section has two widgets: logs that need a look, and stuck summaries. Those cards open Log health or Summaries already filtered to **Needs attention** (anything that is not OK). The same Status filter is on both screens, with that option plus each concrete status.

The section links Log health, Summaries, One log, and One summary. Admin only enables screens a section links to, so Open on a table row can reach the detail screens.

**Log health** lists each registered log. Columns are name, owning gem, table name, approximate rows, storage, maintenance status, retention, month layout, and summary count. Approximate rows and storage come from PostgreSQL `pg_class.reltuples` and `pg_total_relation_size(pg_class.oid)` (or `child.oid` on partitions). They are estimates. Maintenance status is a colored badge: OK, Waiting, Missing month, or Cleanup waiting. Missing month uses `RecordingStudioLogs.missing_partitions`, which compares attached partitions to the maintenance window. Cleanup status is read on each page load.

**One log** shows configuration: owning gem, model, table, timestamp column, root column, retention, and partition interval.

**Summaries** and **One summary** show aggregation progress and recent run rows, including failures. Status on those tables is the same badge treatment.

## Authorization

Admin's controller authenticates, then `RecordingStudioAdmin::Authorization.authorize!` checks Accessible `:view` on the admin root. A missing actor, a missing access recording, or a denied grant is 403. Logs does not add a second policy and does not register Resource actions, so there is no write path on these screens.
