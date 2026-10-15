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

  def test_a_late_row_after_success_keeps_the_month
    name = expired_month
    insert_view(Date.new(2020, 1, 15), "PressKit")
    aggregate_month(Date.new(2020, 1, 1), Date.new(2020, 1, 31))
    insert_view(Date.new(2020, 1, 20), "PressKit")

    blocked = RecordingStudioLogs.cleanup_retention!

    assert_includes blocked.blocked, name
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)

    aggregate_month(Date.new(2020, 1, 1), Date.new(2020, 1, 31))
    RecordingStudioLogs.cleanup_retention!
    refute RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)
  end

  def test_a_dormant_consumer_keeps_the_month
    name = expired_month
    aggregate_month(Date.new(2020, 1, 1), Date.new(2020, 1, 31))
    register_dormant_consumer

    blocked = RecordingStudioLogs.cleanup_retention!

    assert_includes blocked.blocked, name
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)
  end

  def test_a_consumer_registered_before_cleanup_keeps_the_month
    name = expired_month
    aggregate_month(Date.new(2020, 1, 1), Date.new(2020, 1, 31))
    register_later_consumer

    blocked = RecordingStudioLogs.cleanup_retention!
    assert_includes blocked.blocked, name
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)

    aggregate_month(Date.new(2020, 1, 1), Date.new(2020, 1, 31))
    RecordingStudioLogs.cleanup_retention!
    refute RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)
  ensure
    drop_extra("rs_logs_spec_later_counts", "LaterCount")
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

  def test_unscoped_summaries_drop_a_deleted_owners_counts
    day = Date.new(2026, 10, 14)
    kept = SecureRandom.uuid
    removed = SecureRandom.uuid
    register_total
    insert_view(day, "PressKit", root_recording_id: kept)
    insert_view(day, "PressKit", root_recording_id: removed)
    RecordingStudioLogs.aggregate_day!(day)
    assert_equal 2, TotalSummary.sum(:views)

    RecordingStudioLogs.delete_for_root(root_recording_id: removed)

    assert_equal [kept], ViewLog.pluck(:root_recording_id)
    assert_equal [kept], KitSummary.pluck(:root_recording_id)
    assert_equal 1, TotalSummary.sum(:views)
  ensure
    drop_extra("rs_logs_spec_totals", "TotalSummary")
  end

  def test_a_dormant_consumer_blocks_owner_deletion
    day = Date.new(2026, 10, 14)
    root_id = SecureRandom.uuid
    insert_view(day, "PressKit", root_recording_id: root_id)
    RecordingStudioLogs.aggregate_day!(day)
    register_dormant_consumer

    RecordingStudioLogs.delete_for_root(root_recording_id: root_id)

    assert_equal [root_id], ViewLog.pluck(:root_recording_id)
    assert_equal [root_id], KitSummary.pluck(:root_recording_id)
  end

  def test_a_rebuild_waiting_on_the_aggregation_lock_cannot_restore_a_deleted_root
    day = Date.new(2026, 10, 14)
    kept = SecureRandom.uuid
    removed = SecureRandom.uuid
    register_total
    insert_view(day, "PressKit", root_recording_id: kept)
    insert_view(day, "PressKit", root_recording_id: removed)
    holding = Queue.new
    release = Queue.new
    lock_name = RecordingStudioLogs::Lock.key("presskits/press_kit_views", day)
    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.transaction do
          RecordingStudioLogs::Lock.acquire(connection, lock_name)
          holding << :locked
          release.pop
          KitSummary.create!(day: day, root_recording_id: removed, recording_id: SecureRandom.uuid, views: 1)
          KitSummary.create!(day: day, root_recording_id: kept, recording_id: SecureRandom.uuid, views: 1)
        end
      end
    end
    holding.pop
    deleter = Thread.new { RecordingStudioLogs.delete_for_root(root_recording_id: removed) }
    wait_for_advisory_wait
    release << :go
    assert writer.join(10), "the waiting rebuild did not finish"
    assert deleter.join(10), "owner deletion did not finish"

    assert_equal [kept], ViewLog.pluck(:root_recording_id)
    assert_equal [kept], KitSummary.where(day: day).pluck(:root_recording_id)
    assert_equal 1, TotalSummary.sum(:views)
  ensure
    release << :go if defined?(release) && release
    writer.join(5) if defined?(writer) && writer
    deleter.join(5) if defined?(deleter) && deleter
    drop_extra("rs_logs_spec_totals", "TotalSummary")
  end

  def test_cleanup_rechecks_the_month_while_holding_the_aggregation_lock
    name = expired_month
    aggregate_month(Date.new(2020, 1, 1), Date.new(2020, 1, 31))
    other = ActiveRecord::Base.connection_pool.checkout
    other.begin_db_transaction
    lock_name = RecordingStudioLogs::Lock.key("presskits/press_kit_views", Date.new(2020, 1, 1))
    RecordingStudioLogs::Lock.acquire(other, lock_name)
    cleanup = Thread.new { RecordingStudioLogs.cleanup_retention! }
    wait_for_advisory_wait
    insert_view(Date.new(2020, 1, 18), "PressKit")
    other.commit_db_transaction
    report = cleanup.value

    assert_includes report.blocked, name
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)
  ensure
    if other
      other.rollback_db_transaction if other.open_transactions.positive?
      ActiveRecord::Base.connection_pool.checkin(other)
    end
  end

  def test_non_partitioned_log_keeps_rows_until_a_summary_succeeds
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

    RecordingStudioLogs.cleanup_retention!
    assert_equal 2, plain.count

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
    assert_equal 0, RecordingStudioLogs::Admin::Catalog.stuck_count
    month = RecordingStudioLogs::Partitioning::Names.partition(VIEW_TABLE, Time.now.utc.beginning_of_month)
    RecordingStudioLogs::Partitioning::Catalog.drop(month, ActiveRecord::Base.connection)
    health = RecordingStudioLogs::Admin::Catalog.logs.find { |row| row.name == ViewLog.name }
    assert_equal "Missing month", health.status
    assert_equal 1, RecordingStudioLogs::Admin::Catalog.attention_count
    assert RecordingStudioLogs::Admin::Catalog.partitions_for(ViewLog.name).any?
    assert_empty RecordingStudioLogs::Admin::Catalog.runs_for("missing/aggregation")
  end

  def test_metrics_sums_seven_views_on_that_day_and_leaves_a_gap_empty
    require "recording_studio_metrics"
    day = Date.new(2026, 10, 14)
    root_id = SecureRandom.uuid
    recording_id = SecureRandom.uuid
    7.times { insert_view(day, "PressKit", root_recording_id: root_id, recording_id: recording_id) }
    RecordingStudioLogs.aggregate_day!(day)
    RecordingStudioLogs.finalize!
    RecordingStudioLogs.finalize!

    result = RecordingStudioMetrics.execute(
      "presskits_press_kit_views.views",
      context: RecordingStudioMetrics::Context.new(
        scope: :root, system: true, workspace_id: root_id, timezone: "America/Los_Angeles",
        timestamp: Time.utc(2026, 10, 16, 12)
      ),
      start_at: Time.utc(2026, 10, 14), end_at: Time.utc(2026, 10, 16), interval: :day
    )
    filled = result.data.select { |point| point[:value] }

    assert_equal([["2026-10-14", 7]], filled.map { |point| [point[:date], point[:value].to_i] })
    assert(result.data.any? { |point| point[:value].nil? })
    definition = RecordingStudioMetrics.find("presskits_press_kit_views.views")
    assert_equal "count", definition.unit
    assert_equal "utc_day_rollup", definition.semantics
    assert_equal "Fresh UTC-day rollup of views. A day with no summary is empty.", definition.description
  end

  def test_metrics_follow_the_root_recording_when_its_id_differs_from_the_recordable
    require "recording_studio_metrics"
    day = Date.new(2026, 10, 14)
    root_id = SecureRandom.uuid
    7.times { insert_view(day, "PressKit", root_recording_id: root_id) }
    RecordingStudioLogs.aggregate_day!(day)
    RecordingStudioLogs.finalize!
    root = Struct.new(:id, :recordable_id).new(root_id, SecureRandom.uuid)

    result = RecordingStudioMetrics.execute(
      "presskits_press_kit_views.views",
      context: RecordingStudioMetrics::Context.new(
        scope: :root, system: true, root_recording: root, timezone: "UTC",
        timestamp: Time.utc(2026, 10, 16, 12)
      ),
      start_at: Time.utc(2026, 10, 14), end_at: Time.utc(2026, 10, 16), interval: :day
    )
    point = result.data.find { |row| row[:date] == "2026-10-14" }

    assert_equal 7, point[:value].to_i
  end

  def test_a_bad_start_at_is_a_metrics_input_error
    require "recording_studio_metrics"
    RecordingStudioLogs.aggregate_day!(Date.new(2026, 10, 14))
    RecordingStudioLogs.finalize!
    bad = Object.new
    def bad.to_time = "nope"
    context = RecordingStudioMetrics::Context.new(
      scope: :root, system: true, workspace_id: SecureRandom.uuid, timezone: "UTC",
      timestamp: Time.utc(2026, 10, 16, 12)
    )

    assert_raises(RecordingStudioMetrics::Errors::InvalidDateRange) do
      RecordingStudioMetrics.execute(
        "presskits_press_kit_views.views",
        context: context, start_at: bad, end_at: Time.utc(2026, 10, 16), interval: :day
      )
    end
  end

  def test_a_row_committed_while_cleanup_waits_keeps_the_month
    name = expired_month
    aggregate_month(Date.new(2020, 1, 1), Date.new(2020, 1, 31))
    other = ActiveRecord::Base.connection_pool.checkout
    other.begin_db_transaction
    other.execute("LOCK TABLE #{other.quote_table_name(VIEW_TABLE)} IN ROW EXCLUSIVE MODE")
    cleanup = Thread.new { RecordingStudioLogs.cleanup_retention! }
    wait_for_relation_wait
    insert_held_row(other, Time.utc(2020, 1, 18, 12))
    other.commit_db_transaction
    report = cleanup.value

    assert_includes report.blocked, name
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(VIEW_TABLE, name)
    assert_equal 1, ViewLog.where(occurred_at: Time.utc(2020, 1, 18, 12)).count
  ensure
    if other
      other.rollback_db_transaction if other.open_transactions.positive?
      ActiveRecord::Base.connection_pool.checkin(other)
    end
    cleanup&.join(5)
  end

  def test_a_log_with_no_aggregations_keeps_an_expired_month
    table = "rs_logs_spec_bare"
    RecordingStudioLogs::Schema.partitioned_log(table, timestamp_column: :occurred_at) do |definition|
      definition.uuid :root_recording_id
    end
    bare = named_model("BareLog", table)
    RecordingStudioLogs.register(
      model: bare, timestamp_column: :occurred_at, retention: 1.day, root_column: :root_recording_id, owner: "Bare"
    )
    RecordingStudioLogs.ensure_partition!(bare, Time.utc(2020, 1, 15))
    bare.create!(occurred_at: Time.utc(2020, 1, 15, 12), root_recording_id: SecureRandom.uuid)
    name = "rs_logs_spec_bare_2020_01"

    report = RecordingStudioLogs.cleanup_retention!

    assert_includes report.blocked, name
    assert RecordingStudioLogs::Partitioning::Catalog.exists?(table, name)
    assert_equal 1, bare.count
  ensure
    drop_extra(table, "BareLog")
  end

  def test_a_late_row_without_created_at_keeps_the_month
    table = "rs_logs_spec_arrivals"
    summary_name = "rs_logs_spec_arrival_counts"
    RecordingStudioLogs::Schema.partitioned_log(table, timestamp_column: :occurred_at) do |definition|
      definition.uuid :root_recording_id
    end
    create_summary(summary_name)
    source = named_model("ArrivalLog", table)
    summary = named_model("ArrivalCount", summary_name)
    RecordingStudioLogs.register(
      model: source, timestamp_column: :occurred_at, retention: 1.day, root_column: :root_recording_id,
      owner: "Arrivals", aggregatable: { root_recording_id: { group: true } }
    )
    RecordingStudioLogs.aggregate(
      source: source, name: "host/arrival_counts", summary_model: summary,
      group_by: [:root_recording_id], measurements: { views: :count }, owner: "Arrivals"
    )
    day = Date.new(2020, 1, 15)
    RecordingStudioLogs.ensure_partition!(source, Time.utc(2020, 1, 15))
    source.create!(occurred_at: Time.utc(2020, 1, 15, 8), root_recording_id: SecureRandom.uuid)
    RecordingStudioLogs.aggregate_day!(day)
    source.create!(occurred_at: Time.utc(2020, 1, 15, 18), root_recording_id: SecureRandom.uuid)
    name = "rs_logs_spec_arrivals_2020_01"

    report = RecordingStudioLogs.cleanup_retention!

    assert_includes report.blocked, name
    assert_equal 2, source.count
  ensure
    ActiveRecord::Base.connection.drop_table(summary_name, if_exists: true) if defined?(summary_name)
    drop_extra(table, "ArrivalLog") if defined?(table)
    self.class.send(:remove_const, "ArrivalCount") if self.class.const_defined?("ArrivalCount", false)
  end

  def test_non_partitioned_cleanup_deletes_only_days_a_success_covers
    connection = ActiveRecord::Base.connection
    connection.create_table :rs_logs_spec_plain_days, id: :uuid do |table|
      table.datetime :occurred_at, null: false
      table.uuid :root_recording_id
      table.timestamps
    end
    create_summary("rs_logs_spec_plain_day_counts")
    plain = named_model("PlainDayLog", "rs_logs_spec_plain_days")
    summary = named_model("PlainDayCount", "rs_logs_spec_plain_day_counts")
    RecordingStudioLogs.register(
      model: plain, timestamp_column: :occurred_at, partition_interval: nil, retention: 1.day,
      root_column: :root_recording_id, owner: "Plain days", aggregatable: {
        root_recording_id: { filter: [:eq], group: true }
      }
    )
    RecordingStudioLogs.aggregate(
      source: plain, name: "host/plain_day_counts", summary_model: summary,
      group_by: [:root_recording_id], measurements: { views: :count }, owner: "Plain days"
    )
    now = Time.utc(2026, 10, 15, 15)
    plain.create!(occurred_at: Time.utc(2026, 10, 14, 10), root_recording_id: SecureRandom.uuid)
    plain.create!(occurred_at: Time.utc(2026, 10, 14, 16), root_recording_id: SecureRandom.uuid)

    RecordingStudioLogs::Retention::Cleaner.call(now: now)
    assert_equal 2, plain.count

    RecordingStudioLogs.aggregate_day!(Date.new(2026, 10, 14))
    RecordingStudioLogs::Retention::Cleaner.call(now: now)
    assert_equal ["2026-10-14 16:00:00"], stamp_list(plain)

    plain.create!(occurred_at: Time.utc(2026, 10, 13, 10), root_recording_id: SecureRandom.uuid)
    plain.create!(occurred_at: Time.utc(2026, 10, 14, 9), root_recording_id: SecureRandom.uuid)
    RecordingStudioLogs.aggregate_day!(Date.new(2026, 10, 13))
    RecordingStudioLogs::Retention::Cleaner.call(now: now)

    assert_equal ["2026-10-14 09:00:00", "2026-10-14 16:00:00"], stamp_list(plain)
  ensure
    connection = ActiveRecord::Base.connection
    connection.drop_table("rs_logs_spec_plain_day_counts", if_exists: true)
    connection.drop_table("rs_logs_spec_plain_days", if_exists: true)
    %w[PlainDayLog PlainDayCount].each do |name|
      self.class.send(:remove_const, name) if self.class.const_defined?(name)
    end
  end

  def test_log_health_reuses_one_cleanup_read
    expired_month
    ActiveSupport::IsolatedExecutionState.delete(:recording_studio_logs_cleanup)
    RecordingStudioLogs::Admin::Catalog.logs
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      queries << args.last[:sql]
    end
    RecordingStudioLogs::Admin::Catalog.attention_count

    assert_equal(0, queries.count { |sql| sql.include?("aggregation_runs") })
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    ActiveSupport::IsolatedExecutionState.delete(:recording_studio_logs_cleanup)
  end

  def test_jobs_rebuild_real_rows
    day = Time.now.utc.to_date - 1
    insert_view(day, "PressKit")

    RecordingStudioLogs::PartitionMaintenanceJob.perform_now
    RecordingStudioLogs::DailyAggregationJob.perform_now
    RecordingStudioLogs::DailyAggregationJob.perform_now
    RecordingStudioLogs::BackfillJob.perform_now("presskits/press_kit_views", day.iso8601, day.iso8601)
    RecordingStudioLogs::ReconciliationJob.perform_now
    preview = RecordingStudioLogs::RetentionCleanupJob.perform_now(dry_run: true)

    assert_equal 1, KitSummary.sum(:views)
    assert_kind_of RecordingStudioLogs::Retention::CleanupReport, preview
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

  def insert_view(day, resource_type, root_recording_id: SecureRandom.uuid, recording_id: SecureRandom.uuid)
    ViewLog.create!(view_attributes(Time.utc(day.year, day.month, day.day, 12), resource_type: resource_type,
                                                                                root_recording_id: root_recording_id,
                                                                                recording_id: recording_id))
  end

  def view_attributes(occurred_at, resource_type:, root_recording_id: SecureRandom.uuid,
                      recording_id: SecureRandom.uuid)
    { occurred_at: occurred_at, resource_type: resource_type, root_recording_id: root_recording_id,
      recording_id: recording_id }
  end

  def run_status(name, day)
    RecordingStudioLogs::AggregationRun.find_by!(aggregation_name: name, day: day).status
  end

  def expired_month
    RecordingStudioLogs.ensure_partition!(ViewLog, Time.utc(2020, 1, 1))
    "rs_logs_spec_views_2020_01"
  end

  def aggregate_month(from, to)
    each_day_in(from, to) { |day| RecordingStudioLogs.aggregate_day!(day) }
  end

  def register_dormant_consumer
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "ghost/views", summary_model: "Missing::Summary",
      group_by: [:root_recording_id], measurements: { views: :count }, owner: "Ghost"
    )
  end

  def register_later_consumer
    create_summary("rs_logs_spec_later_counts")
    model = self.class.const_set(:LaterCount, Class.new(ActiveRecord::Base) do
      self.table_name = "rs_logs_spec_later_counts"
    end)
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/later_views", summary_model: model,
      group_by: [:root_recording_id], measurements: { views: :count }, owner: "Host"
    )
  end

  def register_total
    connection = ActiveRecord::Base.connection
    connection.drop_table(:rs_logs_spec_totals, if_exists: true)
    connection.create_table :rs_logs_spec_totals, id: :uuid do |table|
      table.date :day, null: false
      table.string :resource_type
      table.integer :views, null: false, default: 0
      table.timestamps
    end
    model = self.class.const_set(:TotalSummary, Class.new(ActiveRecord::Base) do
      self.table_name = "rs_logs_spec_totals"
    end)
    RecordingStudioLogs.aggregate(
      source: ViewLog, name: "host/all_views", summary_model: model,
      group_by: [:resource_type], measurements: { views: :count }, owner: "Host"
    )
  end

  def drop_extra(table_name, constant)
    ActiveRecord::Base.connection.drop_table(table_name, if_exists: true)
  ensure
    self.class.send(:remove_const, constant) if self.class.const_defined?(constant, false)
  end

  def wait_for_advisory_wait
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.02 until advisory_waiting? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    flunk "the aggregation lock was not waited on" unless advisory_waiting?
  end

  def advisory_waiting?
    sql = "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'advisory' AND NOT granted"
    ActiveRecord::Base.connection.select_value(sql).to_i.positive?
  end

  def wait_for_relation_wait
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 8
    sleep 0.02 until relation_waiting? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    flunk "cleanup did not wait on the table lock" unless relation_waiting?
  end

  def relation_waiting?
    sql = "SELECT COUNT(*) FROM pg_locks WHERE locktype = 'relation' AND NOT granted"
    ActiveRecord::Base.connection.select_value(sql).to_i.positive?
  end

  def stamp_list(model)
    model.order(:occurred_at).map { |row| row.occurred_at.utc.strftime("%Y-%m-%d %H:%M:%S") }
  end

  def insert_held_row(connection, occurred_at)
    root = connection.quote(SecureRandom.uuid)
    recording = connection.quote(SecureRandom.uuid)
    connection.execute(<<~SQL.squish)
      INSERT INTO #{connection.quote_table_name(VIEW_TABLE)}
        (id, occurred_at, resource_type, root_recording_id, recording_id, created_at, updated_at)
      VALUES (gen_random_uuid(), #{connection.quote(occurred_at)}, 'PressKit', #{root}, #{recording},
              CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
    SQL
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
