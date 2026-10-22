# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.0] - 2026-10-22

### Changed
- Logs registers daily count and sum summaries through the public Metrics `register` API. UTC buckets use `bucket_timezone: "UTC"`. Empty days are zero-filled (`fill_gaps: true`). Root isolation uses `scope_attribute` from the log's root column and `scope_value: :root_recording_id`.
- RecordingStudio_metrics is pinned to `~> 0.6.1` (GitHub tag `v0.6.1`).
- Missing `config/recording_studio_logs.yml` is skipped, including a nil config path. Invalid YAML and invalid `config.x` values raise.
- The install generator no longer injects Tailwind or Flatpack `@source` paths. The engine no longer ships a template home controller or root route.

### Removed
- Prepends into RecordingStudioMetrics (`MetricsBoundary`, timeseries `SummarySeries`, and the workspace-id fallback for summary scope).
- Engine `class_eval` `extend_model` / `extend_controller` hooks.
- Dead `day_for`, unused summary `filter.inspect`, template kit leftovers (`docs/gem_template`, `.github/agents`, `bin/rename_gem`, fetch-skills and rename tests), and stale root `MIGRATION_NOTES.md` / `UPDATE_SUMMARY.md`.

### Upgrade notes
- See [UPGRADING.md](UPGRADING.md). Hosts need Metrics 0.6.1 or newer for the logs bridge. Pass `root_recording:` when querying Logs series. Empty days are zeros. The caller timezone does not regroup UTC days. `group_by` on a Logs series raises `InvalidGroupBy`.

## [0.6.0] - 2026-10-21

### Added
- `RecordingStudioLogs.aggregate` accepts `period:` (`:hour`, `:day`, `:week`, `:month`) and `every:` (default `1`). Existing daily summaries keep `period: :day, every: 1`.
- `period_column:` names the summary's period-start column. The default is `:day`, a date, so current summary tables do not need a migration. Hour periods need a datetime column.
- `count:` is `:scheduled` (default), `:sync`, or `:async`. Sync recounts that period in the same request after a model save. Async enqueues `AggregatePeriodJob` for that period. Both always rebuild the whole period. `insert_all` skips the hooks.
- `count_after:` waits after a period ends before the scheduled path counts it. `include_current:` also refreshes the open period.
- `aggregate_due!`, `aggregate_period!`, `AggregationJob`, `AggregatePeriodJob`, and `reconcile!(now:, today:)`.
- `RecordingStudioLogs::AggregationJob` counts every aggregation whose period has closed, plus `count_after` and the current period when asked. `DailyAggregationJob` still counts yesterday for daily aggregations.
- Install and upgrade migrations store aggregation runs on `period_start` instead of `day`.

### Changed
- Daily cleanup methods moved from `retention/cleaner.rb` into `retention/day_cleaner.rb`. Partition release now goes through `range_ready?`/`range_fresh?`. Daily behaviour is unchanged.
- `aggregate_day!` now skips non-calendar-day aggregations.
- MetricsBridge only publishes calendar-day aggregations.
- Admin RunRow day is now `period_start`.
- `Runner.call` takes `period_start:`.
- Reconciliation recounts the last `reconciliation_days` periods per aggregation. Daily aggregations still use that integer as days.
- Retention deletes raw rows only after every covering period is closed and counted.
- Owner deletion rebuilds unscoped summaries for the affected period starts.
- Owner deletion loads distinct hour-truncated timestamps for a root instead of every raw row time.
- Aggregation runs upgrade copies `day` as midnight without session time zone conversion.

### Upgrade notes
- Run `bin/rails generate recording_studio_logs:migrations` and migrate **before** booting 0.6.0 code. Hosts that already have the runs table get `period_start` from the upgrade migration. See [UPGRADING.md](UPGRADING.md).
- `interval: :daily` still registers a one-day summary. Use `period:` for hour, week, and month buckets.
- Schedule `AggregationJob` often if you use a non-daily period. `DailyAggregationJob` ignores those aggregations.

## [0.5.1] - 2026-10-21

### Added
- Guide for deciding contractual vs analytics logs, aggregation size, and when to add a summary table: [Decide retention and aggregation before you add a summary](docs/guides/data-retention-and-aggregation.md).

### Upgrade notes
- Docs only. No host change. Reload Logs 0.5.1 if you pin the gem by tag.

## [0.5.0] - 2026-10-20

### Added
- Log health and Summaries take a Status filter. Needs a look and Summaries stuck open those screens on **Needs attention** (not OK), which matches the widget counts.
- Status on Log health, Summaries, and One summary runs renders as a Flatpack badge: OK green, Failed and Missing table red, Missing month and Cleanup waiting amber, Waiting grey.

### Fixed
- One log and One summary are linked from the Logs section, so Admin enables those screens for an enabled logs root. Open on a row no longer 404s.
- Log health no longer memoizes the cleanup dry-run in `IsolatedExecutionState` for the life of the process. A new expired month or finished summary shows on the next load.

### Changed
- The Logs section treats Log health as a normal link, not a primary button.

### Upgrade notes
- Reload Logs 0.5.0. No host change. Staff who already have the Logs section get the detail screens, Status filter, and live cleanup status.

## [0.4.2] - 2026-10-20

### Fixed
- Admin log health size queries qualify `pg_class.oid` when joining `pg_namespace`, so PostgreSQL no longer raises `PG::AmbiguousColumn`. Partition catalog size queries already used `child.oid`.

### Upgrade notes
- No host change. Reload Logs 0.4.2 so Admin log health can read table size.

## [0.4.1] - 2026-10-19

### Fixed
- `MetricsBoundary.install!` still prepends the Metrics executor, but it only rejects `group_by` for metrics Logs owns or bridges. Other gems keep the `group_by` dimensions they registered. Logs timeseries still raise `RecordingStudioMetrics::Errors::InvalidFilter`.

### Upgrade notes
- Hosts that load Logs and then call `RecordingStudioMetrics.execute` with `group_by` on another gem's metric (for example `api_requests.server_errors_over_time`) get that grouping instead of `InvalidFilter`. Logs-published timeseries still reject `group_by`. No registration change is required.

## [0.4.0] - 2026-10-16

### Added
- Semantics, cutover, and adoption guides. Count and sum are the only timeseries Metrics publishes. Cancelling a subscription never deletes logs. The host calls `delete_for_root`.
- `Schema.root_and_time_index`, `Schema.inspect_table`, `Schema.partition_compatibility`, and `Cutover` copy, validate, root-column, and backfill helpers.
- `RecordingStudioLogs.missing_partitions` reports months in the maintenance window that are not attached. Admin health uses that list.
- Admin log health shows table name, approximate rows, storage, and maintenance status. The detail screen shows configuration only.
- Dummy `legacy_download_logs` is an unpartitioned Downloadable-shaped table. Dummy tests copy it onto a partitioned table, backfill a root column, match counts, and roll back.

### Upgrade notes
- This release adds helpers and screens. Existing registrations do not need a data migration.
- Call `Schema.root_and_time_index` from a producing gem's log migration when lookups are by root and time.
- Read [Log semantics](docs/semantics.md) and [Copy and switch a live log table](docs/cutover.md) before partitioning a live table.
- Admin is still unmounted in this dummy because of the Flatpack pin. Screen definitions are tested without a browser.

## [0.3.0] - 2026-10-15

### Added
- `RecordingStudioLogs.register` and `RecordingStudioLogs.aggregate` for producer logs and namespaced daily summaries.
- Monthly range partitions, a composite primary key of `(id, timestamp)`, and `EnsuresPartition` for inserts into a month that is not attached yet.
- Daily aggregation with delete-and-insert replacement, backfill, and a short UTC reconciliation window.
- Retention that drops a month only after it is fully expired and every summary of that month has finished. `:indefinite` keeps the table.
- `delete_for_root` for one owner's raw rows and the summaries that group by that root.
- ActiveJob classes a host can schedule. No queue gem is bundled.
- An optional metrics bridge. Count and sum summaries become timeseries when `RecordingStudioMetrics` is loaded. Summaries are still written when it is absent.
- Optional read-only admin screens when `RecordingStudioAdmin` is loaded. They show health and summary progress, not raw rows.
- A dummy site-view log with press-kit and press-center summaries, plus an indefinite download-shaped log.

### Fixed
- Boot stays up when the database does not exist yet. Metrics registration waits until the summary table can be checked, so an asset build can load the app before `db:create`.

### Removed
- The template page model, page migration, and example capability.

### Upgrade notes
- This is the first logs release. There is no compatibility shim for the template page table or example capability.
- Run `bin/rails generate recording_studio_logs:migrations`, then `bin/rails db:migrate`, to add aggregation and maintenance run tables.
- Producing gems ship their own log migrations. Consumers ship their own summary migrations. Initializers do not create those tables.
- Existing production log tables stay as they are until that gem ships a manual partition cutover. This gem does not rewrite them.
- Schedule `PartitionMaintenanceJob`, `DailyAggregationJob`, `ReconciliationJob`, and `RetentionCleanupJob` in the host. Day boundaries are UTC.
- Set `config.retention_for("ModelName", duration)` to override a gem default. One policy per table.
- Call `RecordingStudioLogs.finalize!` after registering. The engine also finalizes on boot.
- Admin screens appear only when `RecordingStudioAdmin` is already on the host. Grant them with Accessible on an admin root.

## [0.2.3] - 2026-10-01

### Changed
- Dummy and root GitHub tags: Recording Studio `v4.2.0` → `v4.2.1`, Accessible `v0.9.1` → `v0.10.1`, Root Switchable `v0.5.0` → `v0.5.1`, FlatPack `v0.1.177` → `v0.1.196`.
- Root and dummy lockfiles refreshed to current releases, including Rails `8.1.4`. The gem test suite requires `minitest-mock` because Minitest 6 moved `Object#stub` out of minitest.
- Dummy `image_processing` constraint `~> 1.2` → `~> 2.2`. `ruby-vips` is a direct dependency with `require: false`, because image_processing 2 treats the processor as optional and the app should boot before libvips is installed.
- Dummy schema includes the Accessible 0.10 `recording_studio_access_invitations` table.

### Fixed
- Dummy Tailwind now scans the installed FlatPack components and Recording Studio views. `tailwindcss:build` links those engines under `test/dummy/vendor/engines`, because git gems are checked out as `bundler/gems/<name>-<rev>` and the old `vendor/bundle/**/flatpack/` glob never matched.
- Dummy layouts load `flat_pack/application` (component CSS such as `.fp-button`) on both the Devise layout and the Recording Studio default layout.
- Dummy importmap pins `flat_pack/tiptap` and `flat_pack/local_time`, matching the FlatPack install contract.

### Upgrade notes
- Point host and dummy Gemfiles at Recording Studio `v4.2.1`, Accessible `v0.10.1`, Root Switchable `v0.5.1`, and FlatPack `v0.1.196`.
- Run `bin/rails generate recording_studio_accessible:migrations`, then `bin/rails db:migrate`, to add access invitations.
- Rebuild Tailwind after the FlatPack tag bump: `bin/rails tailwindcss:build`.
- Hosts still on `gem "image_processing", "~> 1.2"` should move to `~> 2.2` and add `gem "ruby-vips"` (or `gem "mini_magick"`).

## [0.2.2] - 2026-09-11

### Changed
- Gemspec `recording_studio` floor `~> 4.1` → `~> 4.2` so copied addons match Accessible 0.7+.
- Dummy Accessible tag `v0.6.0` → `v0.9.1`; FlatPack tag `v0.1.133` → `v0.1.177`. Recording Studio stays `v4.2.0`; Root Switchable stays `v0.5.0`.
- Root `Gemfile.lock` Rails `8.1.1` → `8.1.3.1` (with `json` `2.21.2`, `mail` `2.9.1`, `nokogiri` `1.19.4`) to match the dummy host lock and Active Storage CVE-2026-66066.
- Extra Cloud Agent skills now come from the plugin catalog (`skill-sources.json`) instead of a hardcoded extra URL. A missing or invalid catalog is skipped so Recording Studio skills still fetch. Failures still warn and exit 0.
- Docs and pin tests no longer mention `recording_studio/v3.0.0`, FlatPack `v0.1.133`, or Accessible `v0.6.0`.

### Added
- After skills, the Cloud Agent fetch hook lists plugin `*.mdc` rules from `RecordingStudio_cursor_plugin` into `.cursor/rules/` (gitignored, not packaged). A missing rules directory warns and skips. Failures still exit 0.
- Cloud Agent skill-fetch hook so copied addons load Recording Studio skills at Build time. `.cursor/environment.json` names the environment `recording-studio-gem-template`. `install` is `.cursor/install.sh`, which runs `.cursor/fetch-skills.sh` after provisioning. `snapshot` is omitted on purpose so Builds run install instead of reusing a laptop Personal snapshot. The script lists `recording-studio-*` skill ids from the public GitHub contents API and writes each `SKILL.md` into `.cursor/skills/` (gitignored, not packaged). Failures warn and still exit 0.
- Dummy Accessible migration for `depends_on_recording_id` (Accessible 0.8+).

### Upgrade notes
- Bump addon gemspecs to `spec.add_dependency "recording_studio", "~> 4.2"`.
- Point host/dummy Gemfiles at Accessible `v0.9.1` and FlatPack `v0.1.177` (Recording Studio tag stays `v4.2.0`).
- Run `bin/rails generate recording_studio_accessible:migrations` then `bin/rails db:migrate`. Do not hand-edit Accessible tables.
- Rebuild Tailwind after the FlatPack tag bump: `bin/rails tailwindcss:build`.
- Align root gem-suite `Gemfile.lock` Rails to `8.1.3.1` if it is still on `8.1.1`.

## [0.2.1] - 2026-09-01

### Added
- Full Cloud Agent development environment. `.cursor/install.sh` now provisions the whole stack at Build time on Cursor's default image — Ruby (pinned by `.ruby-version`), PostgreSQL 16, gem dependencies for both the gem and the dummy host app, the seeded dummy database, and compiled Tailwind/FlatPack CSS — then runs the existing `.cursor/fetch-skills.sh`. `snapshot` stays omitted so Builds run `install` as before.
- `.cursor/start.sh` per-boot hook that starts PostgreSQL and waits for readiness.
- `.cursor/environment.json` now declares `start` plus `rails-server` and `tailwind-watch` terminals and exposes port 3000, so a fresh Cloud Agent boots straight into a running, signed-in-ready dummy app.

### Notes
- The install script is idempotent; running it against a warm machine reuses the existing Ruby, packages, and gems.
- No gem runtime code changed. `.cursor/` files are excluded from the packaged gem.

## [0.2.0] - 2026-08-21

New addons copied from this template are born on Recording Studio 4.x.

### Added
- Gemspec dependency `recording_studio`, `~> 4.1`
- Dummy host wiring for Accessible (`enable_capability(:accessible, on: Workspace)`) and an opt-in `RecordingStudio::Capabilities::Example.to` mixin. `.to` wraps core 4.2.0 `include_for` (not a fourth verb, and not a raw `enable_capability` / `set_capability_options` path). Installing the gem does not enable the mixin globally; only dummy Workspace opts in.
- `bin/rename_gem` leftover-identity rewrite/verification for README, homepage, and changelog URLs that still say `RecordingStudioLogs` or point at `bowerbird-app/recording_studio_logs`

### Changed
- Dummy GitHub tags: Recording Studio `v4.2.0`, Accessible `v0.6.0`, Root Switchable `v0.5.0`, FlatPack `v0.1.133`
- Dummy authenticated layout is Recording Studio's default layout plus FlatPack CSS/JS; Devise keeps its own sign-in layout
- Dummy app security pins: Rails `8.1.3.1`, `json` `2.21.2`, `mail` `2.9.1`, Brakeman `8.0.6`
- Require `RecordingStudio::Hooks` and `RecordingStudio::Services::BaseService` from core instead of shipping copies

### Removed
- Copied `lib/recording_studio_logs/hooks.rb` and `lib/recording_studio_logs/services/base_service.rb`
- Product-shipped `ExampleService`
- Custom `flat_pack_sidebar` authenticated shell

### Upgrade notes
- Point dummy or host Gemfiles at Recording Studio `v4.2.0` (not `recording_studio/v3.0.0`)
- Add `spec.add_dependency "recording_studio", "~> 4.1"` to addon gemspecs
- Include `RecordingStudio::UsesDefaultLayout` (or set `layout "recording_studio/default_layout"`) for authenticated screens
- Delete any copied Hooks or BaseService files and require the core classes
- Keep recordable declarations; they are required, not a v3-only concern
- If Accessible is bundled, call `RecordingStudio.enable_capability(:accessible, on: Workspace)` (or your root type)

## [0.1.2] - 2026-07-21

### Changed
- Bumped the dummy app FlatPack dependency from `v0.1.33` to `v0.1.129`

## [0.1.1] - 2026-04-28

### Changed
- Bumped the dummy app FlatPack dependency from `0.1.2` to `0.1.33` and pinned it by tag in `test/dummy/Gemfile`

## [0.1.0] - 2025-12-04

### Added
- Initial release
- Rails mountable engine structure
- PostgreSQL with UUID primary keys support
- TailwindCSS v4 integration
- GitHub Codespaces devcontainer configuration
- Docker Compose setup with PostgreSQL and Redis
- Install generator for host applications
- Comprehensive README and documentation
- Basic test suite with Minitest

[Unreleased]: https://github.com/bowerbird-app/recording_studio_logs/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/bowerbird-app/recording_studio_logs/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/bowerbird-app/recording_studio_logs/compare/v0.5.1...v0.6.0
[0.5.1]: https://github.com/bowerbird-app/recording_studio_logs/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/bowerbird-app/recording_studio_logs/compare/v0.4.2...v0.5.0
[0.4.2]: https://github.com/bowerbird-app/recording_studio_logs/compare/v0.4.1...v0.4.2
[0.4.1]: https://github.com/bowerbird-app/recording_studio_logs/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/bowerbird-app/recording_studio_logs/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/bowerbird-app/recording_studio_logs/compare/v0.2.3...v0.3.0
[0.2.3]: https://github.com/bowerbird-app/recording_studio_logs/releases/tag/v0.2.3
[0.2.2]: https://github.com/bowerbird-app/recording_studio_logs/releases/tag/v0.2.2
[0.2.1]: https://github.com/bowerbird-app/recording_studio_logs/releases/tag/v0.2.1
[0.2.0]: https://github.com/bowerbird-app/recording_studio_logs/releases/tag/v0.2.0
[0.1.2]: https://github.com/bowerbird-app/recording_studio_logs/releases/tag/v0.1.2
[0.1.1]: https://github.com/bowerbird-app/recording_studio_logs/releases/tag/v0.1.1
[0.1.0]: https://github.com/bowerbird-app/recording_studio_logs/releases/tag/v0.1.0
