# Aggregate another gem's log

A consumer gem never writes the raw table. It ships a summary table and registers a namespaced aggregation.

## 1. Read the producer contract

Use only columns the producer put in `aggregatable`. If you need a new filter, change the producer first. Two aggregations may read the same raw rows.

## 2. Ship the summary table

```ruby
create_table :press_kit_view_summaries, id: :uuid do |table|
  table.date :day, null: false
  table.uuid :root_recording_id
  table.uuid :recording_id
  table.integer :views, null: false, default: 0
  table.timestamps
end
RecordingStudioLogs::Schema.summary_index(
  :press_kit_view_summaries,
  %i[day root_recording_id recording_id],
  name: "index_press_kit_view_summaries_identity"
)
```

Unique index the identity columns with `nulls_not_distinct: true`. NULL is its own group. Do not also group by the timestamp. The day is the time bucket.

## 3. Register the aggregation

```ruby
RecordingStudioLogs.aggregate(
  source: "SiteView",
  name: "presskits/press_kit_views",
  summary_model: "PressKitViewSummary",
  filter: { resource_type: "PressKit" },
  group_by: %i[root_recording_id recording_id],
  measurements: { views: :count },
  owner: "Press kits"
)
```

The name is `owner/purpose`. Rebuilding a period replaces that period's rows, so a retry does not double-count. Defaults are `period: :day, every: 1, count: :scheduled`. Pass `period: :hour` with a datetime `period_column:` when you need hour buckets.

Group by the log's root column when owner deletion should drop those summary rows. A summary that omits the root is rebuilt for the affected period starts instead, and `delete_for_root` still lists it as unscoped.

## 4. Query

Read the summary model. When Metrics is loaded, only `count` and `sum` become timeseries. Average, minimum, and maximum stay on the table. See [Site views, press kits, and press centers](site-views-press-kits.md).
