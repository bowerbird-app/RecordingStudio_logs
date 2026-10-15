# frozen_string_literal: true

class CreateRecordingStudioLogsDemonstration < ActiveRecord::Migration[8.1]
  def up
    site_views
    sample_downloads
    summary_table(:press_kit_view_summaries)
    summary_table(:press_center_view_summaries)
    summary_table(:sample_download_counts)
  end

  def down
    %i[sample_download_counts press_center_view_summaries press_kit_view_summaries
       sample_downloads site_views].each do |name|
      drop_table name, if_exists: true, force: :cascade
    end
  end

  private

  def site_views
    partitioned(:site_views) do |table|
      table.string :resource_type, null: false
      shared_columns(table)
    end
  end

  def sample_downloads
    partitioned(:sample_downloads) { |table| shared_columns(table) }
  end

  def partitioned(name)
    RecordingStudioLogs::Schema.partitioned_log(name, timestamp_column: :occurred_at, connection: connection) do |table|
      yield table
    end
  end

  def shared_columns(table)
    table.uuid :root_recording_id
    table.uuid :recording_id
    table.timestamps
  end

  def summary_table(name)
    create_table name, id: :uuid do |table|
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
end
