# frozen_string_literal: true

require "test_helper"

class LogsRegistryTest < Minitest::Test
  class ViewLog
    def self.logs_fixture? = true
  end

  class PressKitSummary
    def self.logs_fixture? = true
  end

  class PressCenterSummary
    def self.logs_fixture? = true
  end

  class DownloadLog
    def self.logs_fixture? = true
  end

  class DownloadSummary
    def self.logs_fixture? = true
  end

  def setup
    @original = RecordingStudioLogs.registry
    RecordingStudioLogs.instance_variable_set(:@registry, RecordingStudioLogs::Registry.new)
    RecordingStudioLogs.configuration.clear_retention_overrides!
  end

  def teardown
    RecordingStudioLogs.instance_variable_set(:@registry, @original)
    RecordingStudioLogs.configuration.clear_retention_overrides!
  end

  def test_one_log_accepts_many_aggregations_from_other_namespaces
    register_views
    register_press_kit
    register_press_center

    assert_equal 2, RecordingStudioLogs.aggregations.size
    assert_equal %w[press_centers/press_center_views presskits/press_kit_views],
                 RecordingStudioLogs.aggregations.map(&:name).sort
  end

  def test_aggregation_can_be_registered_before_its_source
    register_press_kit
    register_views

    assert_equal "LogsRegistryTest::ViewLog", RecordingStudioLogs.aggregations.first.log.model_name
  end

  def test_missing_source_gem_stays_dormant
    RecordingStudioLogs.aggregate(
      source: "Missing::ViewLog",
      name: "presskits/press_kit_views",
      summary_model: "Missing::PressKitSummary",
      measurements: { views: :count }
    )

    RecordingStudioLogs.finalize!

    assert RecordingStudioLogs.aggregations.first.dormant?
  end

  def test_loaded_source_without_a_log_registration_fails_finalize
    RecordingStudioLogs.aggregate(
      source: ViewLog,
      name: "presskits/press_kit_views",
      summary_model: PressKitSummary,
      measurements: { views: :count }
    )

    error = assert_raises(RecordingStudioLogs::InvalidRegistration) { RecordingStudioLogs.finalize! }
    assert_includes error.message, "not registered"
  end

  def test_names_must_be_namespaced
    register_views

    error = assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs.aggregate(
        source: ViewLog, name: :press_kit_views, summary_model: PressKitSummary, measurements: { views: :count }
      )
    end
    assert_includes error.message, "presskits/press_kit_views"
  end

  def test_consumers_cannot_group_or_filter_undeclared_columns
    register_views

    error = assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs.aggregate(
        source: ViewLog,
        name: "presskits/press_kit_views",
        summary_model: PressKitSummary,
        filter: { ip_address: "127.0.0.1" },
        measurements: { views: :count }
      )
    end
    assert_includes error.message, "ip_address"
  end

  def test_day_is_not_also_a_group
    register_views

    error = assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs.aggregate(
        source: ViewLog,
        name: "presskits/press_kit_views",
        summary_model: PressKitSummary,
        group_by: [:occurred_at],
        measurements: { views: :count }
      )
    end
    assert_includes error.message, "time dimension"
  end

  def test_hourly_interval_is_rejected
    register_views

    assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs.aggregate(
        source: ViewLog,
        name: "presskits/press_kit_views",
        summary_model: PressKitSummary,
        interval: :hourly,
        measurements: { views: :count }
      )
    end
  end

  def test_host_retention_override_replaces_the_gem_default
    register_views
    RecordingStudioLogs.configuration.retention_for("LogsRegistryTest::ViewLog", 5.days)

    assert_equal 5.days, RecordingStudioLogs.logs.first.retention
  end

  def test_the_same_owner_can_register_an_aggregation_again
    register_views
    register_press_kit
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "presskits/press_kit_views", summary_model: PressKitSummary,
      group_by: [:root_recording_id], owner: "Press kits", measurements: { views: :count }
    )

    assert_equal 1, RecordingStudioLogs.aggregations.size
    assert_equal [:root_recording_id], RecordingStudioLogs.registry.aggregation("presskits/press_kit_views").group_by
  end

  def test_a_different_owner_cannot_take_an_aggregation_name
    register_views
    register_press_kit

    error = assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs.aggregate(
        source: ViewLog, name: "presskits/press_kit_views", summary_model: PressCenterSummary,
        group_by: [:root_recording_id], owner: "Press centers", measurements: { views: :count }
      )
    end

    assert_includes error.message, "Press kits"
    assert_equal "Press kits", RecordingStudioLogs.registry.aggregation("presskits/press_kit_views").owner
  end

  def test_re_registering_the_same_log_replaces_it
    register_views
    RecordingStudioLogs.register(
      model: ViewLog, timestamp_column: :occurred_at, retention: 1.day, aggregatable: view_columns
    )

    assert_equal 1.day, RecordingStudioLogs.logs.first.declared_retention
    assert_equal 1, RecordingStudioLogs.logs.size
  end

  def test_a_log_does_not_need_an_aggregation
    register_views

    assert_empty RecordingStudioLogs.aggregations
    assert_equal 1, RecordingStudioLogs.logs.size
  end

  def test_sum_requires_a_declared_measurement_column
    register_views

    error = assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs.aggregate(
        source: ViewLog,
        name: "presskits/press_kit_views",
        summary_model: PressKitSummary,
        measurements: { total_duration: { sum: :duration_ms } }
      )
    end
    assert_includes error.message, "duration_ms"
  end

  def test_optional_partitioning
    RecordingStudioLogs.register(model: DownloadLog, timestamp_column: :occurred_at, partition_interval: nil)

    refute RecordingStudioLogs.logs.first.partitioned?
  end

  private

  def register_views
    RecordingStudioLogs.register(
      model: ViewLog,
      timestamp_column: :occurred_at,
      retention: 12.months,
      root_column: :root_recording_id,
      owner: "Site views",
      aggregatable: view_columns
    )
  end

  def register_press_kit
    RecordingStudioLogs.aggregate(
      source: ViewLog,
      name: "presskits/press_kit_views",
      summary_model: PressKitSummary,
      filter: { resource_type: "PressKit" },
      group_by: %i[root_recording_id recording_id],
      owner: "Press kits",
      measurements: { views: :count }
    )
  end

  def register_press_center
    RecordingStudioLogs.aggregate(
      source: ViewLog,
      name: "press_centers/press_center_views",
      summary_model: PressCenterSummary,
      filter: { resource_type: "PressCenter" },
      group_by: %i[root_recording_id recording_id],
      owner: "Press centers",
      measurements: { views: :count }
    )
  end

  def view_columns
    {
      resource_type: { filter: [:eq], group: true },
      root_recording_id: { filter: [:eq], group: true },
      recording_id: { filter: [:eq], group: true }
    }
  end
end
