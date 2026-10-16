# frozen_string_literal: true

class CreateLegacyDownloadLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :legacy_download_logs, id: :uuid do |table|
      table.datetime :occurred_at, null: false
      table.uuid :recording_id
      table.string :ip_address
      table.string :user_agent
      table.timestamps
    end
    add_foreign_key :legacy_download_logs, :recording_studio_recordings, column: :recording_id
  end
end
