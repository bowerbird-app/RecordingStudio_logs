# Create a producing gem log

A producing gem owns the table and the insert path. RecordingStudioLogs owns partitions, retention, and the contract other gems may aggregate.

## 1. Add the gem

```ruby
gem "recording_studio_logs", github: "bowerbird-app/RecordingStudio_logs", tag: "v0.4.2"
```

Run `bin/rails generate recording_studio_logs:migrations` and migrate. That adds run tables only.

## 2. Ship the log table

New tables use `Schema.partitioned_log` and a primary key of `(id, timestamp)`. Add a root column when owner deletion or rooted summaries matter. Add `Schema.root_and_time_index` for those lookups.

```ruby
RecordingStudioLogs::Schema.partitioned_log(:download_logs, timestamp_column: :occurred_at) do |table|
  table.uuid :root_recording_id
  table.uuid :recording_id
  table.string :ip_address
  table.string :user_agent
  table.timestamps
end
RecordingStudioLogs::Schema.root_and_time_index(
  :download_logs,
  root_column: :root_recording_id,
  timestamp_column: :occurred_at
)
```

An existing production table stays unpartitioned until you follow [Copy and switch a live log table](../cutover.md).

## 3. Register the model

```ruby
class DownloadLog < ApplicationRecord
  self.primary_key = %i[id occurred_at]
  include RecordingStudioLogs::EnsuresPartition
end

RecordingStudioLogs.register(
  model: "DownloadLog",
  timestamp_column: :occurred_at,
  retention: 90.days,
  root_column: :root_recording_id,
  owner: "Downloadable",
  aggregatable: {
    root_recording_id: { filter: [:eq], group: true },
    recording_id: { filter: [:eq], group: true }
  }
)
```

Declare only columns other gems may filter, group, or measure. IP address and user agent stay off that list.

`insert_all` skips `EnsuresPartition`. Call `RecordingStudioLogs.ensure_partition!(DownloadLog, time)` before a bulk insert into a new month.

## 4. Finalize and schedule

Call `RecordingStudioLogs.finalize!` at the end of the initializer. Schedule the jobs in [Schedule log jobs](scheduling.md).
