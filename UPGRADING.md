# Upgrade to 0.7.0

Logs no longer patches RecordingStudioMetrics. Daily count and sum summaries register through the public Metrics API. Pin `recording_studio_metrics` to `~> 0.6` (GitHub tag `v0.6.0`).

1. No migrations in this gem.
2. Registrations now pass `bucket_timezone: "UTC"`, `fill_gaps: false`, and `scope_attribute:` as the log's root column. Empty UTC days stay empty. Hosts pass `workspace_id:` as that root recording id, the same way other Metrics callers pass a workspace id.
3. A bad timezone or a non-time `start_at` still raises `RecordingStudioMetrics::Errors::InvalidDateRange`. That comes from Metrics 0.6, not a Logs prepend.
4. `group_by` on a Logs-published timeseries raises `RecordingStudioMetrics::Errors::InvalidGroupBy` when the metric did not declare grouping. Metrics registered by other gems keep the dimensions they declared.
5. `config/recording_studio_logs.yml` is still optional. A missing file is ignored. Invalid YAML raises. Do not rely on Logs swallowing a bad config file.
6. The engine no longer ships a template home route, Tailwind `@source` installer, or `extend_model` / `extend_controller` class_eval hooks.

If you are still on `0.6.0` or older, complete that release's notes first.
