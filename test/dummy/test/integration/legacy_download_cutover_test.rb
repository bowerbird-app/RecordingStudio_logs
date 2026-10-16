# frozen_string_literal: true

require "test_helper"

class LegacyDownloadCutoverTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  SOURCE = "legacy_download_logs"
  DEST = "legacy_download_logs_partitioned"
  SUMMARY = "legacy_download_counts"

  test "copy and switch matches counts then rollback restores the source" do
    cleanup_cutover_tables
    LegacyDownloadLog.delete_all
    connection = ActiveRecord::Base.connection
    recording_id = insert_recording(connection)
    root_id = connection.select_value(<<~SQL.squish)
      SELECT root_recording_id FROM recording_studio_recordings WHERE id = #{connection.quote(recording_id)}
    SQL

    day = Date.new(2026, 10, 14)
    3.times do
      LegacyDownloadLog.create!(
        occurred_at: Time.utc(2026, 10, 14, 15),
        recording_id: recording_id,
        ip_address: "203.0.113.10",
        user_agent: "spec"
      )
    end
    before = LegacyDownloadLog.count
    report = RecordingStudioLogs::Schema.partition_compatibility(SOURCE, timestamp_column: :occurred_at)

    refute report.compatible
    assert_equal 3, before

    RecordingStudioLogs::Schema.partitioned_log(DEST, timestamp_column: :occurred_at, connection: connection) do |table|
      table.uuid :root_recording_id
      table.uuid :recording_id
      table.string :ip_address
      table.string :user_agent
      table.timestamps
    end
    RecordingStudioLogs::Schema.root_and_time_index(
      DEST, root_column: :root_recording_id, timestamp_column: :occurred_at, connection: connection
    )
    month = Time.utc(2026, 10, 1)
    RecordingStudioLogs::Partitioning::Catalog.create(
      DEST, RecordingStudioLogs::Partitioning::Names.partition(DEST, month), month, month.next_month, connection
    )
    RecordingStudioLogs::Cutover.add_root_column(SOURCE)
    RecordingStudioLogs::Cutover.backfill_root(SOURCE)
    columns = %i[id occurred_at recording_id ip_address user_agent root_recording_id created_at updated_at]
    RecordingStudioLogs::Cutover.copy(from: SOURCE, to: DEST, columns: columns)
    check = RecordingStudioLogs::Cutover.validate(from: SOURCE, to: DEST)

    assert check.matched?
    assert_equal 3, connection.select_value(<<~SQL.squish).to_i
      SELECT COUNT(*) FROM #{connection.quote_table_name(DEST)}
      WHERE root_recording_id = #{connection.quote(root_id)}
    SQL

    create_summary(connection)
    register_cutover_models
    RecordingStudioLogs.aggregate_day!(day)

    assert_equal before, LegacyDownloadCount.sum(:views)

    connection.drop_table(DEST, if_exists: true, force: :cascade)
    assert_equal before, LegacyDownloadLog.count
    forget_cutover_registration
    RecordingStudioLogs.aggregate_day!(day)
  ensure
    forget_cutover_registration
    LegacyDownloadLog.delete_all
    connection = ActiveRecord::Base.connection
    connection.drop_table(SUMMARY, if_exists: true)
    connection.drop_table(DEST, if_exists: true, force: :cascade)
    if connection.column_exists?(SOURCE, :root_recording_id)
      connection.remove_column(SOURCE, :root_recording_id)
    end
  end

  private

  def insert_recording(connection)
    id = SecureRandom.uuid
    now = connection.quote(Time.now.utc)
    quoted = connection.quote(id)
    connection.execute(<<~SQL.squish)
      INSERT INTO recording_studio_recordings
        (id, recordable_id, recordable_type, root_recording_id, created_at, updated_at)
      VALUES (#{quoted}, #{quoted}, 'LegacyDownloadLog', #{quoted}, #{now}, #{now})
    SQL
    id
  end

  def register_cutover_models
    unless defined?(LegacyPartitionedDownloadLog)
      Object.const_set(:LegacyPartitionedDownloadLog, Class.new(ApplicationRecord) do
        self.table_name = DEST
        self.primary_key = %i[id occurred_at]
      end)
    end
    unless defined?(LegacyDownloadCount)
      Object.const_set(:LegacyDownloadCount, Class.new(ApplicationRecord) { self.table_name = SUMMARY })
    end
    RecordingStudioLogs.register(
      model: LegacyPartitionedDownloadLog, timestamp_column: :occurred_at, root_column: :root_recording_id,
      owner: "Downloads", aggregatable: {
        root_recording_id: { filter: [:eq], group: true },
        recording_id: { filter: [:eq], group: true }
      }
    )
    RecordingStudioLogs.aggregate(
      source: LegacyPartitionedDownloadLog, name: "downloadable/legacy_cutover",
      summary_model: LegacyDownloadCount,
      group_by: %i[root_recording_id recording_id], measurements: { views: :count }, owner: "Downloads"
    )
  end

  def forget_cutover_registration
    registry = RecordingStudioLogs.registry
    mutex = registry.instance_variable_get(:@mutex)
    mutex.synchronize do
      registry.instance_variable_get(:@aggregations).delete("downloadable/legacy_cutover")
      registry.instance_variable_get(:@logs).delete("LegacyPartitionedDownloadLog")
    end
  end

  def cleanup_cutover_tables
    connection = ActiveRecord::Base.connection
    connection.drop_table(SUMMARY, if_exists: true)
    connection.drop_table(DEST, if_exists: true, force: :cascade)
    return unless connection.column_exists?(SOURCE, :root_recording_id)

    connection.remove_column(SOURCE, :root_recording_id)
  end

  def create_summary(connection)
    connection.create_table SUMMARY, id: :uuid do |table|
      table.date :day, null: false
      table.uuid :root_recording_id
      table.uuid :recording_id
      table.integer :views, null: false, default: 0
      table.timestamps
    end
    RecordingStudioLogs::Schema.summary_index(
      SUMMARY, %i[day root_recording_id recording_id], name: "index_legacy_download_counts_identity",
      connection: connection
    )
  end
end
