# frozen_string_literal: true

require "test_helper"
require "pg"

class LogsPostgresTest < Minitest::Test
  VIEW_TABLE = "rs_logs_spec_views"
  DOWNLOAD_TABLE = "rs_logs_spec_downloads"
  KIT_TABLE = "rs_logs_spec_kit_views"
  CENTER_TABLE = "rs_logs_spec_center_views"
  DOWNLOAD_SUMMARY = "rs_logs_spec_download_counts"

  class ViewLog < ActiveRecord::Base
    self.table_name = VIEW_TABLE
    self.primary_key = %i[id occurred_at]
    include RecordingStudioLogs::EnsuresPartition
  end

  class DownloadLog < ActiveRecord::Base
    self.table_name = DOWNLOAD_TABLE
    self.primary_key = %i[id occurred_at]
  end

  class BrokenSummary < ActiveRecord::Base
    self.table_name = "rs_logs_missing"
  end

  class KitSummary < ActiveRecord::Base
    self.table_name = KIT_TABLE
  end

  class CenterSummary < ActiveRecord::Base
    self.table_name = CENTER_TABLE
  end

  class DownloadSummary < ActiveRecord::Base
    self.table_name = DOWNLOAD_SUMMARY
  end

  def setup
    connect!
    reset_registry!
    build_schema
    register_sources
  end

  def teardown
    drop_schema
    RecordingStudioLogs.reset!
    ActiveRecord::Base.connection_pool.disconnect!
  end

  def test_inserts_route_into_the_month_partition
    RecordingStudioLogs.maintain_partitions!
    occurred_at = Time.utc(2026, 10, 14, 12)
    RecordingStudioLogs.ensure_partition!(ViewLog, occurred_at)
    row = ViewLog.create!(view_attributes(occurred_at, resource_type: "PressKit"))

    partition = ActiveRecord::Base.connection.select_value(
      "SELECT tableoid::regclass::text FROM #{VIEW_TABLE} WHERE id = #{ActiveRecord::Base.connection.quote(row[:id])}"
    )

    assert_includes partition, "rs_logs_spec_views_2026_10"
  end

  def test_historical_insert_creates_the_missing_partition
    occurred_at = Time.utc(2024, 3, 2, 8)
    ViewLog.create!(view_attributes(occurred_at, resource_type: "PressKit"))

    assert RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, "rs_logs_spec_views_2024_03")
  end

  def test_primary_key_includes_the_timestamp
    names = ActiveRecord::Base.connection.select_values(<<~SQL)
      SELECT attribute.attname
      FROM pg_index index
      JOIN pg_attribute attribute
        ON attribute.attrelid = index.indrelid AND attribute.attnum = ANY(index.indkey)
      WHERE index.indrelid = '#{VIEW_TABLE}'::regclass AND index.indisprimary
    SQL

    assert_equal %w[id occurred_at], names.sort
  end

  def test_partitioned_table_can_reference_another_table
    ActiveRecord::Base.connection.create_table :rs_logs_spec_parents, id: :uuid
    ActiveRecord::Base.connection.add_foreign_key VIEW_TABLE, :rs_logs_spec_parents, column: :recording_id
    parent_id = ActiveRecord::Base.connection.select_value(
      "INSERT INTO rs_logs_spec_parents (id) VALUES (gen_random_uuid()) RETURNING id"
    )
    row = ViewLog.create!(view_attributes(Time.utc(2026, 10, 2), resource_type: "PressKit", recording_id: parent_id))

    assert_equal parent_id.to_s, row.recording_id.to_s
  end

  def test_concurrent_maintenance_creates_each_month_once
    errors = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { RecordingStudioLogs.maintain_partitions! }
      rescue StandardError => e
        errors << e
      end
    end
    threads.each(&:join)

    assert_empty errors
    current = RecordingStudioLogs::Partitioning::Names.partition(VIEW_TABLE, Time.now.utc.beginning_of_month)
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, current)
  end

  def test_two_aggregations_share_raw_rows_without_double_counting
    day = Date.new(2026, 10, 14)
    insert_view(day, "PressKit")
    insert_view(day, "PressKit")
    insert_view(day, "PressCenter")

    RecordingStudioLogs.aggregate_day!(day)
    RecordingStudioLogs.aggregate_day!(day)

    assert_equal 2, KitSummary.sum(:views)
    assert_equal 1, CenterSummary.sum(:views)
    assert_equal 2, KitSummary.count
    assert_equal 1, CenterSummary.count
    assert_equal 3, ViewLog.count
  end

  def test_late_event_is_included_when_the_day_is_rebuilt
    day = Date.new(2026, 10, 14)
    insert_view(day, "PressKit")
    RecordingStudioLogs.aggregate_day!(day)
    insert_view(day, "PressKit")
    RecordingStudioLogs::Aggregation::Scheduler.reconcile(today: day + 1)

    assert_equal 2, KitSummary.sum(:views)
  end

  def test_backfill_rebuilds_a_range_for_one_aggregation
    first = Date.new(2026, 10, 1)
    second = Date.new(2026, 10, 2)
    insert_view(first, "PressKit")
    insert_view(second, "PressCenter")

    RecordingStudioLogs.backfill!("presskits/press_kit_views", from: first, to: second)

    assert_equal 1, KitSummary.sum(:views)
    assert_equal 0, CenterSummary.count
  end

  def test_one_aggregation_can_fail_without_completing_the_other
    day = Date.new(2026, 10, 14)
    insert_view(day, "PressKit")
    RecordingStudioLogs.aggregate(
      source: ViewLog,
      name: "host/broken_views",
      summary_model: BrokenSummary,
      group_by: [:root_recording_id],
      measurements: { views: :count }
    )

    assert_raises(RecordingStudioLogs::NotReady) { RecordingStudioLogs.aggregate_day!(day) }

    assert_equal 1, KitSummary.sum(:views)
    assert_equal "succeeded", run_status("presskits/press_kit_views", day)
    assert_equal "failed", run_status("host/broken_views", day)
  end

  def test_indefinite_retention_keeps_old_partitions
    RecordingStudioLogs.ensure_partition!(DownloadLog, Time.utc(2020, 1, 15))

    report = RecordingStudioLogs.cleanup_retention!

    refute_includes report.dropped, "rs_logs_spec_downloads_2020_01"
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(DOWNLOAD_TABLE, "rs_logs_spec_downloads_2020_01")
  end

  def test_expired_partition_waits_until_every_aggregation_succeeds
    month = Time.utc(2020, 1, 1)
    RecordingStudioLogs.ensure_partition!(ViewLog, month)
    name = "rs_logs_spec_views_2020_01"

    blocked = RecordingStudioLogs.cleanup_retention!
    assert_includes blocked.blocked, name
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)

    each_day_in(Date.new(2020, 1, 1), Date.new(2020, 1, 31)) do |day|
      RecordingStudioLogs.aggregate_day!(day)
    end

    preview = RecordingStudioLogs.cleanup_retention!(dry_run: true)
    assert_includes preview.dropped, name
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)

    RecordingStudioLogs.cleanup_retention!
    refute RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)
  end

  def test_owner_deletion_removes_one_root_from_logs_and_summaries
    day = Date.new(2026, 10, 14)
    kept = SecureRandom.uuid
    removed = SecureRandom.uuid
    insert_view(day, "PressKit", root_recording_id: kept)
    insert_view(day, "PressKit", root_recording_id: removed)
    RecordingStudioLogs.aggregate_day!(day)

    preview = RecordingStudioLogs.delete_for_root(root_recording_id: removed, dry_run: true)
    assert_equal 1, preview.tables.find { |entry| entry[:table] == VIEW_TABLE }[:rows]
    assert_equal 2, ViewLog.count

    RecordingStudioLogs.delete_for_root(root_recording_id: removed)

    assert_equal [kept], ViewLog.pluck(:root_recording_id)
    assert_equal [kept], KitSummary.pluck(:root_recording_id)
  end

  def test_non_partitioned_log_deletes_expired_rows_after_summaries
    connection = ActiveRecord::Base.connection
    connection.create_table :rs_logs_spec_plain, id: :uuid do |table|
      table.datetime :occurred_at, null: false
      table.uuid :root_recording_id
      table.timestamps
    end
    create_summary("rs_logs_spec_plain_counts")
    plain = named_model("PlainLog", "rs_logs_spec_plain")
    summary = named_model("PlainCount", "rs_logs_spec_plain_counts")
    RecordingStudioLogs.register(
      model: plain, timestamp_column: :occurred_at, partition_interval: nil, retention: 1.day,
      root_column: :root_recording_id, owner: "Plain", aggregatable: {
        root_recording_id: { filter: [:eq], group: true }
      }
    )
    RecordingStudioLogs.aggregate(
      source: plain, name: "host/plain_counts", summary_model: summary,
      group_by: [:root_recording_id], measurements: { views: :count }
    )
    old_day = Time.now.utc.to_date - 3
    plain.create!(occurred_at: Time.utc(old_day.year, old_day.month, old_day.day, 8),
                  root_recording_id: SecureRandom.uuid)
    plain.create!(occurred_at: Time.now.utc, root_recording_id: SecureRandom.uuid)
    (old_day...(Time.now.utc - 1.day).to_date).each { |day| RecordingStudioLogs.aggregate_day!(day) }

    RecordingStudioLogs.cleanup_retention!

    assert_equal 1, plain.count
  ensure
    connection = ActiveRecord::Base.connection
    connection.drop_table("rs_logs_spec_plain_counts", if_exists: true)
    connection.drop_table("rs_logs_spec_plain", if_exists: true)
    %w[PlainLog PlainCount].each { |name| self.class.send(:remove_const, name) if self.class.const_defined?(name) }
  end

  def test_catalog_reports_registered_logs_and_aggregations
    RecordingStudioLogs.maintain_partitions!
    rows = RecordingStudioLogs::Admin::Catalog.logs
    summaries = RecordingStudioLogs::Admin::Catalog.aggregations

    assert_equal 2, rows.size
    assert_includes summaries.map(&:name), "presskits/press_kit_views"
    assert_includes summaries.map(&:name), "press_centers/press_center_views"
    assert_operator RecordingStudioLogs::Admin::Catalog.attention_count, :>=, 0
    assert_operator RecordingStudioLogs::Admin::Catalog.stuck_count, :>=, 0
    assert RecordingStudioLogs::Admin::Catalog.partitions_for(ViewLog.name).any?
    assert_empty RecordingStudioLogs::Admin::Catalog.runs_for("missing/aggregation")
  end

  def test_jobs_are_active_job_and_idempotent
    day = Date.new(2026, 10, 14)
    insert_view(day, "PressKit")

    RecordingStudioLogs::PartitionMaintenanceJob.perform_now
    RecordingStudioLogs::DailyAggregationJob.perform_now(day.iso8601)
    RecordingStudioLogs::DailyAggregationJob.perform_now(day.iso8601)

    assert_equal 1, KitSummary.sum(:views)
    assert_kind_of ActiveJob::Base, RecordingStudioLogs::ReconciliationJob.new
  end

  private

  def connect!
    ActiveRecord::Base.establish_connection(maintenance_config)
    name = database_name
    exists = ActiveRecord::Base.connection.select_value("SELECT 1 FROM pg_database WHERE datname = #{quote_name(name)}")
    ActiveRecord::Base.connection.create_database(name) unless exists
    ActiveRecord::Base.establish_connection(test_config.merge(pool: 5))
    ActiveRecord::Base.connection.execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")
  end

  def build_schema
    connection = ActiveRecord::Base.connection
    RecordingStudioLogs::Schema.install_runs!(connection)
    RecordingStudioLogs::Schema.partitioned_log(VIEW_TABLE, timestamp_column: :occurred_at,
                                                            connection: connection) do |table|
      table.uuid :root_recording_id
      table.uuid :recording_id
      table.string :resource_type, null: false
      table.timestamps
    end
    RecordingStudioLogs::Schema.partitioned_log(DOWNLOAD_TABLE, timestamp_column: :occurred_at,
                                                                connection: connection) do |table|
      table.uuid :root_recording_id
      table.uuid :recording_id
      table.timestamps
    end
    [KIT_TABLE, CENTER_TABLE, DOWNLOAD_SUMMARY].each { |name| create_summary(name) }
  end

  def create_summary(name)
    connection = ActiveRecord::Base.connection
    connection.create_table name, id: :uuid do |table|
      table.date :day, null: false
      table.uuid :root_recording_id
      table.uuid :recording_id
      table.integer :views, null: false, default: 0
      table.timestamps
    end
    RecordingStudioLogs::Schema.summary_index(
      name, %i[day root_recording_id recording_id], name: "index_#{name}_identity", connection: connection
    )
  end

  def register_sources
    RecordingStudioLogs.register(
      model: ViewLog, timestamp_column: :occurred_at, retention: 30.days, root_column: :root_recording_id,
      owner: "Site views", aggregatable: aggregatable_columns
    )
    RecordingStudioLogs.register(
      model: DownloadLog, timestamp_column: :occurred_at, retention: :indefinite, root_column: :root_recording_id,
      partition_interval: :monthly, owner: "Downloads", aggregatable: download_columns
    )
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "presskits/press_kit_views", summary_model: KitSummary,
      filter: { resource_type: "PressKit" }, group_by: %i[root_recording_id recording_id],
      measurements: { views: :count }, owner: "Press kits"
    )
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "press_centers/press_center_views", summary_model: CenterSummary,
      filter: { resource_type: "PressCenter" }, group_by: %i[root_recording_id recording_id],
      measurements: { views: :count }, owner: "Press centers"
    )
    RecordingStudioLogs.aggregate(
      source: DownloadLog, name: "downloadable/download_counts", summary_model: DownloadSummary,
      group_by: %i[root_recording_id recording_id], measurements: { views: :count }, owner: "Downloads"
    )
  end

  def aggregatable_columns
    {
      resource_type: { filter: [:eq], group: true },
      root_recording_id: { filter: [:eq], group: true },
      recording_id: { filter: [:eq], group: true }
    }
  end

  def download_columns
    { root_recording_id: { filter: [:eq], group: true }, recording_id: { filter: [:eq], group: true } }
  end

  def insert_view(day, resource_type, root_recording_id: SecureRandom.uuid)
    ViewLog.create!(view_attributes(Time.utc(day.year, day.month, day.day, 12), resource_type: resource_type,
                                                                                root_recording_id: root_recording_id))
  end

  def view_attributes(occurred_at, resource_type:, root_recording_id: SecureRandom.uuid,
                      recording_id: SecureRandom.uuid)
    { occurred_at: occurred_at, resource_type: resource_type, root_recording_id: root_recording_id,
      recording_id: recording_id }
  end

  def run_status(name, day)
    RecordingStudioLogs::AggregationRun.find_by!(aggregation_name: name, day: day).status
  end

  def each_day_in(from, to)
    date = from
    while date <= to
      yield date
      date += 1
    end
  end

  def named_model(name, table_name)
    self.class.const_set(name, Class.new(ActiveRecord::Base) { self.table_name = table_name })
  end

  def reset_registry!
    RecordingStudioLogs.reset!
  end

  def drop_schema
    connection = ActiveRecord::Base.connection
    [KIT_TABLE, CENTER_TABLE, DOWNLOAD_SUMMARY, VIEW_TABLE, DOWNLOAD_TABLE, "rs_logs_spec_parents",
     "recording_studio_logs_aggregation_runs", "recording_studio_logs_maintenance_runs"].each do |name|
      connection.drop_table(name, if_exists: true, force: :cascade)
    end
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

  def quote_name(name)
    ActiveRecord::Base.connection.quote(name)
  end
end
