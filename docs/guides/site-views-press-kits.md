# Site views, press kits, and press centers

This walkthrough is the dummy app. One partitioned `site_views` table holds every page view. Press kits and press centers each register a daily count over those rows. Metrics reads the kit summary as a timeseries.

Press centers do not have a gem. The dummy stands in as that consumer.

## Raw rows

`SiteView` uses `Schema.partitioned_log` on `occurred_at`, with `resource_type`, `root_recording_id`, and `recording_id`. The producer declares those three as group and filter columns. See `test/dummy/config/initializers/recording_studio_logs.rb`.

Insert two kit views and one center view on the same UTC day, then rebuild twice:

```ruby
RecordingStudioLogs.aggregate_day!(Date.new(2026, 10, 14))
RecordingStudioLogs.aggregate_day!(Date.new(2026, 10, 14))
PressKitViewSummary.sum(:views)
PressCenterViewSummary.sum(:views)
```

The second rebuild does not double the counts. Each summary table keeps only its filter.

## Metrics

When `RecordingStudioMetrics` is loaded, a rooted `count` or `sum` becomes a timeseries. The dummy registers `presskits_press_kit_views.views`. Average, minimum, and maximum are not published. Do not extend Metrics from this gem.

```ruby
result = RecordingStudioMetrics.execute(
  "presskits_press_kit_views.views",
  context: RecordingStudioMetrics::Context.new(
    scope: :root, system: true, workspace_id: root_id, timezone: "America/Los_Angeles",
    timestamp: Time.utc(2026, 10, 16, 12)
  ),
  start_at: Time.utc(2026, 10, 14),
  end_at: Time.utc(2026, 10, 16),
  interval: :day
)
```

Seven kit views on 14 October UTC read as 7 on that date. A day with no summary row stays empty. The reporting time zone does not move the view to 13 October. See [Log semantics](../semantics.md).

The dummy test is `test/dummy/test/integration/logs_demonstration_test.rb`.
