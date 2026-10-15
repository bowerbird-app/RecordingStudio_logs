# frozen_string_literal: true

require "test_helper"

class LogsContractsTest < Minitest::Test
  def test_retention_rejects_zero_and_accepts_the_indefinite_string
    assert_equal :indefinite, RecordingStudioLogs::Retention.normalize("indefinite")

    error = assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs::Retention.normalize(0.days)
    end
    assert_includes error.message, "positive duration"
  end

  def test_partition_names_reject_an_identifier_that_cannot_fit
    long_name = "a" * 56

    assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs::Partitioning::Names.partition(long_name, Time.utc(2020, 1, 1))
    end
    assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs::Partitioning::Names.check_table!(long_name)
    end
  end

  def test_measurements_reject_a_shape_that_is_not_count_or_a_column
    error = assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs::Measurement.parse(views: "nope")
    end
    assert_includes error.message, "measurements"

    connection = Object.new
    def connection.quote_column_name(column) = "\"#{column}\""
    average = RecordingStudioLogs::Measurement.new(:total, :average, :duration_ms)
    minimum = RecordingStudioLogs::Measurement.new(:total, :minimum, :duration_ms)
    maximum = RecordingStudioLogs::Measurement.new(:total, :maximum, :duration_ms)

    assert_equal 'AVG("duration_ms")', average.sql(connection)
    assert_equal 'MIN("duration_ms")', minimum.sql(connection)
    assert_equal 'MAX("duration_ms")', maximum.sql(connection)
  end

  def test_column_contract_rejects_undeclared_use
    contract = RecordingStudioLogs::ColumnContract.new(resource_type: { filter: [:eq] })

    assert_raises(RecordingStudioLogs::InvalidRegistration) { contract.allow_group!(:resource_type) }
    assert_raises(RecordingStudioLogs::InvalidRegistration) { contract.allow_measurement!(:sum, :resource_type) }
    assert_raises(RecordingStudioLogs::InvalidRegistration) { contract.allow_filter!(:ip_address) }
  end

  def test_jobs_call_the_public_api
    calls = []
    RecordingStudioLogs.stub(:cleanup_retention!, ->(dry_run:) { calls << [:cleanup, dry_run] }) do
      RecordingStudioLogs::RetentionCleanupJob.perform_now(dry_run: true)
    end
    RecordingStudioLogs.stub(:backfill!, ->(name, from:, to:) { calls << [:backfill, name, from, to] }) do
      RecordingStudioLogs::BackfillJob.perform_now("presskits/press_kit_views", "2026-10-01", "2026-10-02")
    end
    RecordingStudioLogs.stub(:reconcile!, -> { calls << [:reconcile] }) do
      RecordingStudioLogs::ReconciliationJob.perform_now
    end
    RecordingStudioLogs.stub(:aggregate_day!, ->(day) { calls << [:day, day] }) do
      RecordingStudioLogs::DailyAggregationJob.perform_now
    end

    assert_equal [:cleanup, true], calls[0]
    assert_equal [:backfill, "presskits/press_kit_views", "2026-10-01", "2026-10-02"], calls[1]
    assert_equal [:reconcile], calls[2]
    assert_equal Time.now.utc.to_date - 1, calls[3][1]
  end

  def test_maintenance_history_is_quiet_without_a_connection
    raiser = Object.new
    def raiser.table_exists?(*)
      raise ActiveRecord::ConnectionNotEstablished
    end

    RecordingStudioLogs::MaintenanceRun.stub(:connection, raiser) do
      assert_nil RecordingStudioLogs::MaintenanceRun.latest("partitions", "site_views")
      assert_nil RecordingStudioLogs::MaintenanceRun.record!(
        task: "partitions", subject: "site_views", status: "succeeded"
      )
    end
  end

  def test_admin_registration_waits_until_the_admin_gem_is_loaded
    assert_nil RecordingStudioLogs::Admin.register!
  end

  def test_status_labels_cover_unknown_ranges_and_kept_months
    partition = RecordingStudioLogs::Partitioning::Partition.new(
      name: "old", lower: nil, upper: nil, estimated_rows: nil, bytes: nil
    )
    log = Struct.new(:indefinite?, :retention).new(true, :indefinite)

    assert_equal "Unknown", RecordingStudioLogs::Admin::Status.range_label(partition)
    assert_equal "Kept", RecordingStudioLogs::Admin::Status.expiration_label(log, partition)
    assert_nil RecordingStudioLogs::Admin::Status.bytes(nil)
  end
end
