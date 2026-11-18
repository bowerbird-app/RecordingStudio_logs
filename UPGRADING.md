# Upgrade to 0.8.2

No Logs migration. Gemspec floors stay `recording_studio >= 7.0`, `< 8.0` and `recording_studio_metrics >= 0.9.0`, `< 1.0`.

Development and dummy GitHub pins move to Recording Studio `v7.7.1`, Metrics `v0.9.2`, Accessible `v0.54.1`, Trashable `v1.2.1`, and Admin `v2.19.0`. Flatpack is `v0.1.378` in both Gemfiles. Root Switchable stays `v0.16.0`. Cache moves to `v0.7.1`.

Move those pins together. Accessible 0.54 needs Recording Studio 7.7.0 or newer, below 8.

Trashable 1.0 removes `RecordingStudioTrashable::Hooks` and `configuration.hooks`. This gem does not call them. It also does not use `RecordingStudio::Services::BaseService`.

Hosts moving to Recording Studio 7.7 must run the Recording Studio 7.4, 7.5, and 7.7 migrations. 7.4 adds `index_rs_recordings_on_root_type_created_at_id` on `recording_studio_recordings (root_recording_id, recordable_type, created_at, id)`. 7.5 enforces the root invariant (`root_recording_id` not null, a parentless row is its own root, and the parent/root foreign key). 7.7 replaces `index_rs_recordings_on_root_recording` with `index_rs_recordings_on_root_created_at_id` on `(root_recording_id, created_at, id)`. The dummy does not copy those migrations. Logs does not ship them.

# Upgrade to 0.8.0

`recording_studio` is `>= 7.0`, `< 8.0`. `recording_studio_metrics` is `>= 0.9.0`, `< 1.0`. No new Logs migration.

`RecordingStudio.root_recording_for` only finds a root. It returns `nil` when that recordable has no root, and it does not write. Seeds, setup, and request paths that created a root by looking it up call `create_root_recording!` with an actor. A second call returns the same root and does not append another event.

`create_root_recording!` authorizes with `recording`, `root_recording`, and `parent_recording` all nil. The dummy `authorize_write` allows that write for the signed-in actor (`actor` present, persisted, and equal to `Current.actor`). Do not set `allow_unauthorized_writes`.

Dummy and development GitHub pins move to Recording Studio `v7.0.0`, Metrics `v0.9.0`, Accessible `v0.43.1`, Trashable `v0.16.1`, Root Switchable `v0.15.1`, and Admin `v2.16.0`. Flatpack stays `v0.1.366`. Cache stays `v0.6.3`.

Trashable 0.16 removed `recording_studio_trashable_kept_sql`. The dummy seeds use `Recording.kept`.

Log column contracts are unchanged. Secrets, tokens, passwords, and request fields such as IP address and user agent stay off `aggregatable` unless a producer already named them. Rails parameter filtering in the dummy stays on.

# Upgrade to 0.7.5

No Logs migration. Gemspec floors stay `recording_studio >= 6.1.0` and `recording_studio_metrics >= 0.6.1, < 1.0`.

`RecordingStudioLogs::Retention::RawRows.max_in_window` is removed. Nothing in this gem called it. Keep using `cleanup_retention!` and `delete_for_root`.

Dummy and development GitHub pins move to Recording Studio `v6.10.0`, Flatpack `v0.1.366`, Metrics `v0.8.0`, Trashable `v0.15.0`, Accessible `v0.37.0`, Admin `v2.13.0`, Cache `v0.6.3`, and Root Switchable `v0.15.0`.

Hosts on Recording Studio 6.9 or 6.10 copy core migration `20261114090000_add_root_recording_id_to_recording_studio_events` before writing events. The dummy includes that copy. It backfills `recording_studio_events.root_recording_id`, then adds the root timeline index and the impersonator index. Logs itself ships no new migration.

The dummy host sets `RecordingStudio` `config.authorize_write`. Writes need a persisted user and Accessible `:edit` on the root. Access rows are allowed from `AccessCreationContext` or with `:admin`. The dummy root switcher lists roots the actor can `:view`, and the mounted switch page still requires that grant on the current root. The dummy recordings table adds nullable `purge_at` from Trashable 0.14 (`idx_rs_recordings_due_purge_at`).

# Upgrade to 0.7.4

No API or migration change. Root and dummy lockfiles use Rails 8.1.4.1. Rack, nokogiri, loofah, rails-html-sanitizer, and dummy net-ssh stay at the 0.7.3 security floors.

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
