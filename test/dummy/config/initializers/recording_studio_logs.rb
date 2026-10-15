# frozen_string_literal: true

# Demonstration only. Producing gems register their own logs.
# Press centers do not have a gem yet, so this dummy stands in as that consumer.
RecordingStudioLogs.configure do |config|
  config.months_ahead = 2
  config.reconciliation_days = 3
end

RecordingStudioLogs.register(
  model: "SiteView",
  timestamp_column: :occurred_at,
  retention: 30.days,
  root_column: :root_recording_id,
  owner: "Site views",
  aggregatable: {
    resource_type: { filter: [:eq], group: true },
    root_recording_id: { filter: [:eq], group: true },
    recording_id: { filter: [:eq], group: true }
  }
)

RecordingStudioLogs.register(
  model: "SampleDownload",
  timestamp_column: :occurred_at,
  retention: :indefinite,
  root_column: :root_recording_id,
  owner: "Downloads",
  aggregatable: {
    root_recording_id: { filter: [:eq], group: true },
    recording_id: { filter: [:eq], group: true }
  }
)

RecordingStudioLogs.aggregate(
  source: "SiteView",
  name: "presskits/press_kit_views",
  summary_model: "PressKitViewSummary",
  filter: { resource_type: "PressKit" },
  group_by: %i[root_recording_id recording_id],
  measurements: { views: :count },
  owner: "Press kits"
)

RecordingStudioLogs.aggregate(
  source: "SiteView",
  name: "press_centers/press_center_views",
  summary_model: "PressCenterViewSummary",
  filter: { resource_type: "PressCenter" },
  group_by: %i[root_recording_id recording_id],
  measurements: { views: :count },
  owner: "Press centers"
)

RecordingStudioLogs.aggregate(
  source: "SampleDownload",
  name: "downloadable/download_counts",
  summary_model: "SampleDownloadCount",
  group_by: %i[root_recording_id recording_id],
  measurements: { views: :count },
  owner: "Downloads"
)
