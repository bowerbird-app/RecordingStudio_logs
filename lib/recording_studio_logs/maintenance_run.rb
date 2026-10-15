# frozen_string_literal: true

module RecordingStudioLogs
  class MaintenanceRun < ActiveRecord::Base
    self.table_name = "recording_studio_logs_maintenance_runs"

    def self.record!(task:, subject:, status:, details: nil)
      return unless table_ready?

      create!(task: task, subject: subject, status: status, details: details, finished_at: Time.current)
    end

    def self.latest(task, subject)
      return unless table_ready?

      where(task: task, subject: subject).order(finished_at: :desc).first
    end

    def self.table_ready?
      connection.table_exists?(table_name)
    rescue ActiveRecord::ConnectionNotEstablished
      false
    end
  end
end
