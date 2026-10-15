# frozen_string_literal: true

require "test_helper"

class LogsDemonstrationTest < ActiveSupport::TestCase
  test "one site view log feeds press kit and press center summaries" do
    day = Date.new(2026, 10, 14)
    root_id = SecureRandom.uuid
    kit_id = SecureRandom.uuid
    insert_view(day, "PressKit", root_id, kit_id)
    insert_view(day, "PressKit", root_id, kit_id)
    insert_view(day, "PressCenter", root_id, SecureRandom.uuid)

    RecordingStudioLogs.aggregate_day!(day)
    RecordingStudioLogs.aggregate_day!(day)

    assert_equal 2, PressKitViewSummary.sum(:views)
    assert_equal 1, PressCenterViewSummary.sum(:views)
    assert_equal 1, PressKitViewSummary.where(root_recording_id: root_id).count
    assert_equal 3, SiteView.count
  end

  test "metrics can read a daily summary when that gem is loaded" do
    names = RecordingStudioMetrics.for_resource(:presskits_press_kit_views).map(&:identifier)

    assert_includes names, "presskits_press_kit_views.views"
  end

  test "seven views stay on that utc day and a missing day stays empty" do
    day = Date.new(2026, 10, 14)
    root_id = SecureRandom.uuid
    recording_id = SecureRandom.uuid
    7.times { insert_view(day, "PressKit", root_id, recording_id) }
    RecordingStudioLogs.aggregate_day!(day)
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
    filled = result.data.select { |point| point[:value] }

    assert_equal [["2026-10-14", 7]], filled.map { |point| [point[:date], point[:value].to_i] }
    assert result.data.any? { |point| point[:value].nil? }
  end

  test "download counts stay on their own indefinite log" do
    day = Date.new(2026, 10, 14)
    SampleDownload.create!(
      occurred_at: Time.utc(2026, 10, 14, 9),
      root_recording_id: SecureRandom.uuid,
      recording_id: SecureRandom.uuid
    )

    RecordingStudioLogs.aggregate_day!(day)

    assert_equal 1, SampleDownloadCount.sum(:views)
    assert_equal 0, PressKitViewSummary.sum(:views)
  end

  private

  def insert_view(day, resource_type, root_id, recording_id)
    SiteView.create!(
      occurred_at: Time.utc(day.year, day.month, day.day, 15),
      resource_type: resource_type,
      root_recording_id: root_id,
      recording_id: recording_id
    )
  end
end
