# frozen_string_literal: true

require "test_helper"
require "recording_studio_metrics"
require "uri"

class MetricsBridgeTest < Minitest::Test
  TABLE = "rs_logs_bridge_views"
  SUMMARY = "rs_logs_bridge_counts"

  class BridgeView < ActiveRecord::Base
    self.table_name = TABLE
  end

  class BridgeSummary < ActiveRecord::Base
    self.table_name = SUMMARY
  end

  def test_finalize_with_metrics_does_not_query_a_missing_database
    RecordingStudioLogs.reset!
    previous = connection_config
    ActiveRecord::Base.establish_connection(missing_database)
    source = Class.new(ActiveRecord::Base) do
      def self.name = "BootSource"
      self.table_name = "boot_sources"
    end
    summary = Class.new(ActiveRecord::Base) do
      def self.name = "BootSummary"
      self.table_name = "boot_summaries"
    end
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
  end

  def test_execute_reads_the_published_count
    with_published_bridge do
      root_id = SecureRandom.uuid
      BridgeView.create!(occurred_at: Time.utc(2026, 10, 14, 12), root_recording_id: root_id)
      RecordingStudioLogs.aggregate_day!(Date.new(2026, 10, 14))
      RecordingStudioLogs.finalize!
      root = Struct.new(:id, :recordable_id).new(root_id, SecureRandom.uuid)
      result = RecordingStudioMetrics.execute(
        "host_bridge_views.views",
        context: RecordingStudioMetrics::Context.new(
          scope: :root, system: true, root_recording: root, timezone: "America/Los_Angeles",
          timestamp: Time.utc(2026, 10, 16, 12)
        ),
        start_at: Time.utc(2026, 10, 14), end_at: Time.utc(2026, 10, 16), interval: :day
      )

      assert_equal(
        [["2026-10-14", 1], ["2026-10-15", 0]],
        result.data.map { |point| [point[:date], point[:value].to_i] }
      )
    end
  end

  def test_execute_rejects_logs_group_by_and_a_bad_timezone
    with_published_bridge do
      context = RecordingStudioMetrics::Context.new(
        scope: :root, system: true, root_recording: root_recording, timezone: "UTC",
        timestamp: Time.utc(2026, 10, 16, 12)
      )

      assert_raises(RecordingStudioMetrics::Errors::InvalidDateRange) do
        RecordingStudioMetrics::Context.new(
          scope: :root, system: true, root_recording: root_recording, timezone: "Not/AZone"
        )
      end
      assert_raises(RecordingStudioMetrics::Errors::InvalidGroupBy) do
        RecordingStudioMetrics.execute("host_bridge_views.views", context: context, group_by: "ip_address")
      end
    end
  end

  def test_execute_keeps_group_by_on_a_metric_logs_does_not_own
    with_published_bridge { assert_foreign_group_by_still_works }
  end

  def test_bridge_does_not_reopen_metrics_classes
    refute defined?(RecordingStudioLogs::MetricsBoundary)
    refute File.exist?(File.expand_path("../lib/recording_studio_logs/metrics_boundary.rb", __dir__))
    source = File.read(File.expand_path("../lib/recording_studio_logs/metrics_bridge.rb", __dir__))

    refute_includes source, "prepend"
    refute_includes source, "class_eval"
  end

  private

  def assert_foreign_group_by_still_works
    previous = RecordingStudioMetrics.configuration.min_group_size
    table = "rs_logs_bridge_api_requests"
    connection = ActiveRecord::Base.connection
    connection.create_table table, id: :uuid, force: true do |t|
      t.uuid :workspace_id, null: false
      t.string :route_name, null: false
    end
    model = Class.new(ActiveRecord::Base)
    model.table_name = table
    workspace_id = SecureRandom.uuid
    model.create!(workspace_id: workspace_id, route_name: "folders")
    resource = :"bridge_api_requests_#{SecureRandom.hex(4)}"
    RecordingStudioMetrics.register(resource, model: model) do
      count :total, group_by: [:route_name]
    end
    RecordingStudioMetrics.configuration.min_group_size = 1
    result = RecordingStudioMetrics.execute(
      "#{resource}.total",
      context: RecordingStudioMetrics::Context.new(
        scope: :root, system: true, workspace_id: workspace_id, timezone: "UTC"
      ),
      group_by: "route_name",
      cache: false
    )

    assert_equal 1, result.value
    assert_equal :route_name, result.group_by
    assert_equal [{ key: "folders", value: 1 }], result.groups
  ensure
    RecordingStudioMetrics.configuration.min_group_size = previous if previous
    ActiveRecord::Base.connection.drop_table(table, if_exists: true) if defined?(table)
  end

  def with_published_bridge
    connect!
    build_schema
    RecordingStudioLogs.reset!
    RecordingStudioLogs.register(
      model: BridgeView, timestamp_column: :occurred_at, partition_interval: nil,
      root_column: :root_recording_id, owner: "Bridge",
      aggregatable: { root_recording_id: { group: true } }
    )
    RecordingStudioLogs.aggregate(
      source: BridgeView, name: "host/bridge_views", summary_model: BridgeSummary,
      group_by: [:root_recording_id], measurements: { views: :count }, owner: "Bridge"
    )
    RecordingStudioLogs.finalize!
    yield
  ensure
    drop_schema
    RecordingStudioLogs.reset!
    ActiveRecord::Base.connection_pool.disconnect!
  end

  def root_recording
    Struct.new(:id, :recordable_id).new(SecureRandom.uuid, SecureRandom.uuid)
  end

  def connect!
    ActiveRecord::Base.establish_connection(maintenance_config)
    name = database_name
    exists = ActiveRecord::Base.connection.select_value("SELECT 1 FROM pg_database WHERE datname = #{quote_name(name)}")
    ActiveRecord::Base.connection.create_database(name) unless exists
    ActiveRecord::Base.establish_connection(test_config)
    ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")
  end

  def build_schema
    connection = ActiveRecord::Base.connection
    RecordingStudioLogs::Schema.install_runs!(connection)
    connection.create_table TABLE, id: :uuid, force: true do |table|
      table.datetime :occurred_at, null: false
      table.uuid :root_recording_id
      table.timestamps
    end
    connection.create_table SUMMARY, id: :uuid, force: true do |table|
      table.date :day, null: false
      table.uuid :root_recording_id
      table.integer :views, null: false, default: 0
      table.timestamps
    end
  end

  def drop_schema
    return unless ActiveRecord::Base.connected?

    connection = ActiveRecord::Base.connection
    [SUMMARY, TABLE, "recording_studio_logs_aggregation_runs", "recording_studio_logs_maintenance_runs"].each do |name|
      connection.drop_table(name, if_exists: true, force: :cascade)
    end
  end

  def quote_name(name)
    ActiveRecord::Base.connection.quote(name)
  end

  def database_name
    "recording_studio_logs_gem_test"
  end

  def maintenance_config
    test_config.merge(database: "postgres", pool: 1)
  end

  def test_config
    if ENV["DATABASE_URL"]
      uri = URI.parse(ENV["DATABASE_URL"])
      return {
        adapter: "postgresql", host: uri.host, port: uri.port || 5432,
        username: uri.user, password: uri.password, database: database_name
      }
    end

    { adapter: "postgresql", host: ENV.fetch("DB_HOST", "localhost"), port: ENV.fetch("DB_PORT", 5432).to_i,
      username: ENV.fetch("DB_USER", "postgres"), password: ENV.fetch("DB_PASSWORD", "postgres"),
      database: database_name }
  end

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
