# frozen_string_literal: true

require "test_helper"

class MetricsBridgeTest < Minitest::Test
  def test_finalize_with_metrics_does_not_query_a_missing_database
    RecordingStudioLogs.reset!
    previous_metrics = defined?(::RecordingStudioMetrics) ? RecordingStudioMetrics : nil
    Object.send(:remove_const, :RecordingStudioMetrics) if previous_metrics
    previous = connection_config
    metrics = Module.new do
      def self.register(*)
        raise "registered a summary before the database exists"
      end

      def self.for_resource(*)
        []
      end
    end
    Object.const_set(:RecordingStudioMetrics, metrics)
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
    Object.send(:remove_const, :RecordingStudioMetrics) if defined?(RecordingStudioMetrics)
    Object.const_set(:RecordingStudioMetrics, previous_metrics) if previous_metrics
    %w[BootSource BootSummary].each do |name|
      self.class.send(:remove_const, name) if self.class.const_defined?(name, false)
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
