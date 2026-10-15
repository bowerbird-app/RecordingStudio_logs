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

  def test_cleanup_waiting_matches_the_table_and_not_a_prefix
    status = RecordingStudioLogs::Admin::Status
    monthly = Struct.new(:table_name, :indefinite?, :partitioned?, :loaded?).new("site_views", false, true, true)
    plain = Struct.new(:table_name, :indefinite?, :partitioned?, :loaded?).new("plain_views", false, false, true)

    refute status.cleanup_waiting?(monthly, ["site_views_extra_2020_01"])
    assert status.cleanup_waiting?(monthly, ["site_views_2020_01"])
    assert status.cleanup_waiting?(plain, ["plain_views"])
    refute status.cleanup_waiting?(plain, ["plain_views_2020_01"])
    refute status.cleanup_waiting?(monthly, [])
  end

  def test_maintenance_history_is_quiet_without_a_connection
    previous = defined_db_config
    ActiveRecord::Base.establish_connection(
      adapter: "postgresql", host: ENV.fetch("DB_HOST", "localhost"),
      username: ENV.fetch("DB_USER", "postgres"), password: ENV.fetch("DB_PASSWORD", "postgres"),
      database: "recording_studio_logs_missing_boot"
    )

    assert_nil RecordingStudioLogs::MaintenanceRun.latest("partitions", "site_views")
    assert_nil RecordingStudioLogs::MaintenanceRun.record!(
      task: "partitions", subject: "site_views", status: "succeeded"
    )
  ensure
    if previous
      ActiveRecord::Base.establish_connection(previous)
    else
      ActiveRecord::Base.remove_connection
    end
  end

  def defined_db_config
    ActiveRecord::Base.connection_db_config
  rescue ActiveRecord::ConnectionNotEstablished
    nil
  end

  def test_cleanup_status_ignores_an_unloaded_log
    log = RecordingStudioLogs::LogRegistration.new(
      model: "Missing::PlainLog", timestamp_column: :occurred_at, partition_interval: nil
    )

    refute RecordingStudioLogs::Admin::Status.cleanup_waiting?(log, ["missing_plain_logs"])
  end

  def test_admin_registration_waits_until_the_admin_gem_is_loaded
    hidden = Object.send(:remove_const, :RecordingStudioAdmin) if defined?(::RecordingStudioAdmin)

    assert_nil RecordingStudioLogs::Admin.register!
  ensure
    Object.const_set(:RecordingStudioAdmin, hidden) if hidden
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
