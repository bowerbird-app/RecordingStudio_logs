# frozen_string_literal: true

require "test_helper"
require "pg"
require "active_job"

class LogsPeriodPostgresTest < Minitest::Test
  VIEW_TABLE = "rs_logs_period_views"
  DAY_TABLE = "rs_logs_period_day_counts"
  HOUR_TABLE = "rs_logs_period_hour_counts"

  class ViewLog < ActiveRecord::Base
    self.table_name = VIEW_TABLE
    self.primary_key = %i[id occurred_at]
    include RecordingStudioLogs::EnsuresPartition
  end

  class DaySummary < ActiveRecord::Base
    self.table_name = DAY_TABLE
  end

  class HourSummary < ActiveRecord::Base
    self.table_name = HOUR_TABLE
  end

  def setup
    connect!
    RecordingStudioLogs.reset!
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    build_schema
    register_log
  end

  def teardown
    drop_schema
    RecordingStudioLogs.reset!
    ActiveRecord::Base.connection_pool.disconnect!
  end

  def test_default_daily_summary_matches_the_views_shape
    register_daily
    root = SecureRandom.uuid
    insert_view(Time.utc(2026, 10, 14, 9), root_recording_id: root)
    insert_view(Time.utc(2026, 10, 14, 18), root_recording_id: root)
    insert_view(Time.utc(2026, 10, 15, 1), root_recording_id: root)

    RecordingStudioLogs.aggregate_day!(Date.new(2026, 10, 14))
    RecordingStudioLogs.aggregate_day!(Date.new(2026, 10, 14))

    assert_equal 2, DaySummary.where(day: Date.new(2026, 10, 14)).sum(:views)
    assert_equal 1, DaySummary.where(day: Date.new(2026, 10, 14)).count
    assert_equal "succeeded", run_status("host/day_views", Time.utc(2026, 10, 14))
  end

  def test_daily_aggregation_job_skips_hourly_summaries
    register_daily
    register_hourly
    insert_view(Time.utc(2026, 10, 14, 10))
    RecordingStudioLogs::DailyAggregationJob.perform_now(Date.new(2026, 10, 14))

    assert_equal 1, DaySummary.sum(:views)
    assert_equal 0, HourSummary.count
  end

  def test_hour_every_three_counts_one_bucket
    register_hourly
    root = SecureRandom.uuid
    insert_view(Time.utc(2026, 10, 14, 1), root_recording_id: root)
    insert_view(Time.utc(2026, 10, 14, 2, 30), root_recording_id: root)
    insert_view(Time.utc(2026, 10, 14, 4), root_recording_id: root)

    RecordingStudioLogs.aggregate_period!("host/hour_views", Time.utc(2026, 10, 14, 0))
    RecordingStudioLogs.aggregate_period!("host/hour_views", Time.utc(2026, 10, 14, 3))

    assert_equal 2, HourSummary.find_by!(hour: Time.utc(2026, 10, 14, 0)).views
    assert_equal 1, HourSummary.find_by!(hour: Time.utc(2026, 10, 14, 3)).views
  end

  def test_week_and_month_buckets
    register_daily
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/week_views", summary_model: DaySummary,
      period: :week, group_by: [:root_recording_id], measurements: { views: :count }, owner: "Weeks"
    )
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/month_views", summary_model: DaySummary,
      period: :month, every: 3, group_by: [:root_recording_id], measurements: { views: :count }, owner: "Months"
    )
    insert_view(Time.utc(2026, 10, 14, 12))

    RecordingStudioLogs.aggregate_period!("host/week_views", Time.utc(2026, 10, 12))
    RecordingStudioLogs.aggregate_period!("host/month_views", Time.utc(2026, 10, 1))

    assert_equal 1, DaySummary.where(day: Date.new(2026, 10, 12)).sum(:views)
    assert_equal 1, DaySummary.where(day: Date.new(2026, 10, 1)).sum(:views)
  end

  def test_sync_recounts_the_row_period_in_the_same_request
    root = SecureRandom.uuid
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/sync_views", summary_model: DaySummary,
      group_by: [:root_recording_id], measurements: { views: :count },
      count: :sync, owner: "Host"
    )
    insert_view(Time.utc(2026, 10, 14, 12), root_recording_id: root)
    insert_view(Time.utc(2026, 10, 14, 13), root_recording_id: root)

    assert_equal 2, DaySummary.sum(:views)
  end

  def test_sync_create_inside_an_uncommitted_transaction_does_not_write_the_summary
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/sync_views", summary_model: DaySummary,
      group_by: [:root_recording_id], measurements: { views: :count },
      count: :sync, owner: "Host"
    )
    ActiveRecord::Base.transaction do
      insert_view(Time.utc(2026, 10, 14, 12))
      assert_equal 0, DaySummary.count
      raise ActiveRecord::Rollback
    end

    assert_equal 0, DaySummary.count
  end

  def test_aggregate_period_twice_on_the_same_rows_keeps_the_same_sum
    register_daily
    root = SecureRandom.uuid
    insert_view(Time.utc(2026, 10, 14, 9), root_recording_id: root)
    insert_view(Time.utc(2026, 10, 14, 18), root_recording_id: root)

    RecordingStudioLogs.aggregate_period!("host/day_views", Time.utc(2026, 10, 14))
    first = DaySummary.where(day: Date.new(2026, 10, 14)).sum(:views)
    RecordingStudioLogs.aggregate_period!("host/day_views", Time.utc(2026, 10, 14))

    assert_equal 2, first
    assert_equal first, DaySummary.where(day: Date.new(2026, 10, 14)).sum(:views)
    assert_equal 1, DaySummary.where(day: Date.new(2026, 10, 14)).count
  end

  def test_insert_all_skips_sync_hooks
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/sync_views", summary_model: DaySummary,
      group_by: [:root_recording_id], measurements: { views: :count },
      count: :sync, owner: "Host"
    )
    RecordingStudioLogs.ensure_partition!(ViewLog, Time.utc(2026, 10, 14, 12))
    ViewLog.insert_all([view_attributes(Time.utc(2026, 10, 14, 12))])

    assert_equal 0, DaySummary.count
  end

  def test_async_enqueues_one_job_per_period
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/async_views", summary_model: DaySummary,
      group_by: [:root_recording_id], measurements: { views: :count },
      count: :async, owner: "Host"
    )
    3.times { insert_view(Time.utc(2026, 10, 14, 12)) }
    insert_view(Time.utc(2026, 10, 15, 12))

    jobs = period_jobs
    starts = jobs.map { |job| job_args(job).last }

    assert_equal 2, jobs.size
    assert_includes starts, Time.utc(2026, 10, 14).iso8601
    assert_includes starts, Time.utc(2026, 10, 15).iso8601

    jobs.each { |job| RecordingStudioLogs::AggregatePeriodJob.perform_now(*job_args(job)) }

    assert_equal 3, DaySummary.where(day: Date.new(2026, 10, 14)).sum(:views)
    assert_equal 1, DaySummary.where(day: Date.new(2026, 10, 15)).sum(:views)
  end

  def test_scheduled_job_waits_for_count_after
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/late_views", summary_model: DaySummary,
      group_by: [:root_recording_id], measurements: { views: :count },
      count_after: 1.hour, owner: "Host"
    )
    insert_view(Time.utc(2026, 10, 14, 12))

    RecordingStudioLogs.aggregate_due!(now: Time.utc(2026, 10, 15, 0, 30))
    assert_equal 0, DaySummary.count

    RecordingStudioLogs.aggregate_due!(now: Time.utc(2026, 10, 15, 1, 1))
    assert_equal 1, DaySummary.sum(:views)
  end

  def test_include_current_refreshes_the_open_period
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/live_views", summary_model: DaySummary,
      group_by: [:root_recording_id], measurements: { views: :count },
      include_current: true, owner: "Host"
    )
    insert_view(Time.utc(2026, 10, 15, 8))

    RecordingStudioLogs.aggregate_due!(now: Time.utc(2026, 10, 15, 9))
    assert_equal 1, DaySummary.where(day: Date.new(2026, 10, 15)).sum(:views)
  end

  def test_aggregation_job_counts_the_closed_hour
    register_hourly
    insert_view(Time.utc(2026, 10, 14, 10, 15))

    RecordingStudioLogs::AggregationJob.perform_now(Time.utc(2026, 10, 14, 12, 5).iso8601)

    assert_equal 1, HourSummary.find_by!(hour: Time.utc(2026, 10, 14, 9)).views
  end

  def test_hour_period_rejects_a_date_column
    error = assert_raises(RecordingStudioLogs::InvalidRegistration) do
      RecordingStudioLogs.aggregate(
        source: ViewLog, name: "host/bad_hour", summary_model: DaySummary,
        period: :hour, period_column: :day, measurements: { views: :count }, owner: "Host"
      )
    end
    assert_includes error.message, "datetime"
  end

  def test_reconciliation_uses_periods_and_keeps_daily_days
    register_daily
    insert_view(Time.utc(2026, 10, 14, 12))
    RecordingStudioLogs.configuration.reconciliation_days = 3
    RecordingStudioLogs.reconcile!(now: Time.utc(2026, 10, 17, 12))

    assert_equal 1, DaySummary.where(day: Date.new(2026, 10, 14)).sum(:views)
    assert_equal 3, RecordingStudioLogs::AggregationRun.where(
      aggregation_name: "host/day_views", status: "succeeded"
    ).count
  end

  def test_retention_waits_for_a_closed_hour
    connection = ActiveRecord::Base.connection
    connection.create_table :rs_logs_period_plain, id: :uuid do |table|
      table.datetime :occurred_at, null: false
      table.uuid :root_recording_id
      table.string :resource_type, null: false
      table.timestamps
    end
    plain = self.class.const_set(:PlainHourLog, Class.new(ActiveRecord::Base) do
      self.table_name = "rs_logs_period_plain"
    end)
    RecordingStudioLogs.reset!
    RecordingStudioLogs.register(
      model: plain, timestamp_column: :occurred_at, partition_interval: nil, retention: 1.hour,
      root_column: :root_recording_id, owner: "Plain", aggregatable: aggregatable
    )
    RecordingStudioLogs.aggregate(
      source: plain, name: "host/hour_views", summary_model: HourSummary,
      period: :hour, every: 3, period_column: :hour, group_by: [:root_recording_id],
      measurements: { views: :count }, owner: "Host"
    )
    plain.create!(occurred_at: Time.utc(2020, 1, 15, 9, 30), root_recording_id: SecureRandom.uuid,
                  resource_type: "PressKit")
    RecordingStudioLogs.aggregate_period!("host/hour_views", Time.utc(2020, 1, 15, 9))

    waiting = RecordingStudioLogs::Retention::Cleaner.call(now: Time.utc(2020, 1, 15, 10, 45))
    assert_equal 1, plain.count
    assert_includes waiting.blocked, "rs_logs_period_plain"

    RecordingStudioLogs::Retention::Cleaner.call(now: Time.utc(2020, 1, 16, 12))
    assert_equal 0, plain.count
  ensure
    ActiveRecord::Base.connection.drop_table(:rs_logs_period_plain, if_exists: true)
    self.class.send(:remove_const, :PlainHourLog) if self.class.const_defined?(:PlainHourLog, false)
  end

  def test_owner_deletion_rebuilds_an_unscoped_hour_summary
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/all_hours", summary_model: HourSummary,
      period: :hour, every: 3, period_column: :hour, group_by: [:resource_type],
      measurements: { views: :count }, owner: "Host totals"
    )
    kept = SecureRandom.uuid
    removed = SecureRandom.uuid
    insert_view(Time.utc(2026, 10, 14, 1), root_recording_id: kept, resource_type: "PressKit")
    insert_view(Time.utc(2026, 10, 14, 1), root_recording_id: removed, resource_type: "PressKit")
    RecordingStudioLogs.aggregate_period!("host/all_hours", Time.utc(2026, 10, 14, 0))

    RecordingStudioLogs.delete_for_root(root_recording_id: removed)

    assert_equal 1, HourSummary.where(hour: Time.utc(2026, 10, 14, 0), resource_type: "PressKit").sum(:views)
  end

  def test_upgrade_renames_day_to_period_start
    connection = ActiveRecord::Base.connection
    connection.drop_table(:recording_studio_logs_aggregation_runs, if_exists: true)
    connection.create_table :recording_studio_logs_aggregation_runs, id: :uuid do |table|
      table.string :aggregation_name, null: false
      table.date :day, null: false
      table.string :status, null: false
      table.text :error_message
      table.datetime :finished_at
      table.timestamps
    end
    connection.add_index :recording_studio_logs_aggregation_runs, %i[aggregation_name day],
                         unique: true, name: "index_rs_logs_aggregation_runs_on_name_and_day"
    connection.execute(<<~SQL.squish)
      INSERT INTO recording_studio_logs_aggregation_runs
        (id, aggregation_name, day, status, finished_at, created_at, updated_at)
      VALUES (gen_random_uuid(), 'host/day_views', '2026-10-14', 'succeeded',
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL

    RecordingStudioLogs::Schema.upgrade_aggregation_runs!(connection)
    RecordingStudioLogs::Schema.upgrade_aggregation_runs!(connection)

    row = RecordingStudioLogs::AggregationRun.find_by!(aggregation_name: "host/day_views")
    assert_equal Time.utc(2026, 10, 14), row.period_start
    refute connection.column_exists?(:recording_studio_logs_aggregation_runs, :day)
  end

  private

  def register_log
    RecordingStudioLogs.register(
      model: ViewLog, timestamp_column: :occurred_at, retention: 30.days, root_column: :root_recording_id,
      owner: "Site views", aggregatable: aggregatable
    )
  end

  def register_daily
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/day_views", summary_model: DaySummary,
      group_by: [:root_recording_id], measurements: { views: :count }, owner: "Host"
    )
  end

  def register_hourly
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/hour_views", summary_model: HourSummary,
      period: :hour, every: 3, period_column: :hour, group_by: [:root_recording_id],
      measurements: { views: :count }, owner: "Host"
    )
  end

  def aggregatable
    {
      resource_type: { filter: [:eq], group: true },
      root_recording_id: { filter: [:eq], group: true }
    }
  end

  def insert_view(occurred_at, root_recording_id: SecureRandom.uuid, resource_type: "PressKit")
    ViewLog.create!(view_attributes(occurred_at, root_recording_id: root_recording_id, resource_type: resource_type))
  end

  def view_attributes(occurred_at, root_recording_id: SecureRandom.uuid, resource_type: "PressKit")
    { occurred_at: occurred_at, resource_type: resource_type, root_recording_id: root_recording_id }
  end

  def run_status(name, period_start)
    start = RecordingStudioLogs::AggregationRun.coerce_start(period_start)
    RecordingStudioLogs::AggregationRun.find_by!(aggregation_name: name, period_start: start).status
  end

  def period_jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs.select do |job|
      job_class(job) == "RecordingStudioLogs::AggregatePeriodJob"
    end
  end

  def job_class(job)
    job["job_class"] || job[:job_class] || job[:job_class]
  end

  def job_args(job)
    job["arguments"] || job[:arguments]
  end

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
      table.string :resource_type, null: false
      table.timestamps
    end
    connection.create_table DAY_TABLE, id: :uuid do |table|
      table.date :day, null: false
      table.uuid :root_recording_id
      table.integer :views, null: false, default: 0
      table.timestamps
    end
    connection.create_table HOUR_TABLE, id: :uuid do |table|
      table.datetime :hour, null: false
      table.uuid :root_recording_id
      table.string :resource_type
      table.integer :views, null: false, default: 0
      table.timestamps
    end
  end

  def drop_schema
    connection = ActiveRecord::Base.connection
    [HOUR_TABLE, DAY_TABLE, VIEW_TABLE, "recording_studio_logs_aggregation_runs",
     "recording_studio_logs_maintenance_runs"].each do |name|
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
