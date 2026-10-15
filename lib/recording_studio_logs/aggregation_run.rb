# frozen_string_literal: true

module RecordingStudioLogs
  class AggregationRun < ActiveRecord::Base
    self.table_name = "recording_studio_logs_aggregation_runs"

    UPSERT = <<~SQL.squish.freeze
      INSERT INTO %<table>s
        (aggregation_name, day, status, error_message, finished_at, created_at, updated_at)
      VALUES (%<name>s, %<day>s, %<status>s, %<error>s, %<finished>s, %<finished>s, %<finished>s)
      ON CONFLICT (aggregation_name, day)
      DO UPDATE SET status = EXCLUDED.status, error_message = EXCLUDED.error_message,
                    finished_at = EXCLUDED.finished_at, updated_at = EXCLUDED.updated_at
    SQL

    def self.record!(aggregation_name:, day:, status:, error_message: nil, connection: self.connection)
      connection.execute(upsert(connection, aggregation_name, day, status, error_message))
    end

    def self.log_fresh?(log, days, watermark, connection: self.connection)
      return true if days.empty?

      RecordingStudioLogs.registry.aggregations_for(log).all? do |definition|
        fresh?(definition.name, days, watermark, connection: connection)
      end
    end

    def self.fresh?(aggregation_name, days, watermark, connection: self.connection)
      return false if days.empty?

      finished = succeeded_at(connection, aggregation_name, days)
      return false unless finished.size == days.size
      return true if watermark.nil?

      finished.min >= watermark
    end

    def self.upsert(connection, name, day, status, error_message)
      format(
        UPSERT,
        table: connection.quote_table_name(table_name), name: connection.quote(name), day: connection.quote(day),
        status: connection.quote(status), error: connection.quote(error_message),
        finished: connection.quote(Time.current)
      )
    end

    def self.succeeded_at(connection, aggregation_name, days)
      list = days.map { |day| connection.quote(day) }.join(", ")
      sql = <<~SQL.squish
        SELECT finished_at FROM #{connection.quote_table_name(table_name)}
        WHERE aggregation_name = #{connection.quote(aggregation_name)}
          AND status = 'succeeded' AND day IN (#{list})
      SQL
      connection.select_values(sql).filter_map { |value| coerce_time(value) }
    end

    def self.coerce_time(value)
      return value if value.is_a?(Time)
      return if value.blank?

      Time.find_zone!("UTC").parse(value.to_s)
    end
    private_class_method :upsert, :succeeded_at, :coerce_time
  end
end
