# frozen_string_literal: true

require "test_helper"
require "recording_studio_metrics"

class MetricsBridgeTest < Minitest::Test
  def test_finalize_with_metrics_does_not_query_a_missing_database
    RecordingStudioLogs.reset!
    previous = connection_config
    ActiveRecord::Base.establish_connection(missing_database)
    source = self.class.const_set(:BootSource, Class.new(ActiveRecord::Base) do
      self.table_name = "boot_sources"
    end)
    summary = self.class.const_set(:BootSummary, Class.new(ActiveRecord::Base) do
      self.table_name = "boot_summaries"
    end)
    RecordingStudioLogs.register(
      model: source, timestamp_column: :occurred_at, root_column: :root_recording_id,
      aggregatable: { root_recording_id: { group: true } }
    )
    RecordingStudioLogs.aggregate(
      source: source, name: "host/boot_views", summary_model: summary,
      group_by: [:root_recording_id], measurements: { views: :count }
    )

    RecordingStudioLogs.finalize!

    assert_empty RecordingStudioMetrics.for_resource(:host_boot_views)
  ensure
    RecordingStudioLogs.reset!
    restore_connection(previous)
    %w[BootSource BootSummary].each do |name|
      self.class.send(:remove_const, name) if self.class.const_defined?(name, false)
    end
  end

  def test_bad_timezone_and_group_by_are_metrics_input_errors
    RecordingStudioLogs.finalize!
    context = RecordingStudioMetrics::Context.new(
      scope: :root, system: true, workspace_id: "ws", timezone: "UTC"
    )

    assert_raises(RecordingStudioMetrics::Errors::InvalidDateRange) do
      RecordingStudioMetrics::Context.new(scope: :root, system: true, workspace_id: "ws", timezone: "Not/AZone")
    end
    assert_raises(RecordingStudioMetrics::Errors::InvalidFilter) do
      RecordingStudioMetrics.execute("logs.views", context: context, group_by: "ip_address")
    end
    assert_raises(RecordingStudioMetrics::Errors::InvalidFilter) do
      RecordingStudioMetrics.execute("logs.views", context: context, group_by: "email")
    end
  end

  private

  def connection_config
    ActiveRecord::Base.connection_db_config
  rescue ActiveRecord::ConnectionNotEstablished
    nil
  end

  def restore_connection(previous)
    if previous
      ActiveRecord::Base.establish_connection(previous)
    else
      ActiveRecord::Base.connection_handler.clear_all_connections!
    end
  end

  def missing_database
    {
      adapter: "postgresql",
      host: ENV.fetch("DB_HOST", "localhost"),
      port: ENV.fetch("DB_PORT", 5432).to_i,
      username: ENV.fetch("DB_USER", "postgres"),
      password: ENV.fetch("DB_PASSWORD", "postgres"),
      database: "recording_studio_logs_missing_boot"
    }
  end
end
