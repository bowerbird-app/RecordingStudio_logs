# frozen_string_literal: true

module RecordingStudioLogs
  class AggregationRun < ActiveRecord::Base
    self.table_name = "recording_studio_logs_aggregation_runs"

    UPSERT = <<~SQL.squish.freeze
      INSERT INTO %<table>s
        (aggregation_name, period_start, status, error_message, finished_at, created_at, updated_at)
      VALUES (%<name>s, %<start>s, %<status>s, %<error>s, %<finished>s, %<finished>s, %<finished>s)
      ON CONFLICT (aggregation_name, period_start)
      DO UPDATE SET status = EXCLUDED.status, error_message = EXCLUDED.error_message,
                    finished_at = EXCLUDED.finished_at, updated_at = EXCLUDED.updated_at
    SQL

    CLAIM = <<~SQL.squish.freeze
      INSERT INTO %<table>s (aggregation_name, period_start, status, created_at, updated_at)
      VALUES (%<name>s, %<start>s, 'queued', %<now>s, %<now>s)
      ON CONFLICT (aggregation_name, period_start)
      DO UPDATE SET status = 'queued', updated_at = EXCLUDED.updated_at
      WHERE %<table>s.status IS DISTINCT FROM 'queued'
      RETURNING aggregation_name
    SQL

    RELEASE = <<~SQL.squish.freeze
      UPDATE %<table>s SET status = 'running', updated_at = %<now>s
      WHERE aggregation_name = %<name>s AND period_start = %<start>s AND status = 'queued'
    SQL

    def self.record!(aggregation_name:, period_start:, status:, error_message: nil, connection: self.connection)
      start = coerce_start(period_start)
      connection.execute(upsert(connection, aggregation_name, start, status, error_message))
    end

    def self.reserve_queue(aggregation_name:, period_start:, connection: self.connection)
      start = coerce_start(period_start)
      now = connection.quote(Time.current)
      sql = format(
        CLAIM,
        table: connection.quote_table_name(table_name), name: connection.quote(aggregation_name),
        start: connection.quote(start), now: now
      )
      connection.select_value(sql)
    end

    def self.release_queue!(aggregation_name:, period_start:, connection: self.connection)
      start = coerce_start(period_start)
      sql = format(
        RELEASE,
        table: connection.quote_table_name(table_name), name: connection.quote(aggregation_name),
        start: connection.quote(start), now: connection.quote(Time.current)
      )
      connection.execute(sql)
    end

    def self.log_fresh?(log, units, watermark, connection: nil)
      definitions = RecordingStudioLogs.registry.aggregations_for(log)
      return false if units.empty? || definitions.empty?

      connection ||= self.connection
      definitions.all? do |definition|
        starts = Array(units).map { |unit| definition.period.start_for(unit) }.uniq
        fresh?(definition.name, starts, watermark, connection: connection)
      end
    end

    def self.fresh?(aggregation_name, starts, watermark, connection: self.connection)
      starts = Array(starts).map { |start| coerce_start(start) }
      return false if starts.empty?

      finished = succeeded_at(connection, aggregation_name, starts)
      return false unless finished.size == starts.size
      return true if watermark.nil?

      finished.min >= watermark
    end

    def self.range_fresh?(log, lower, upper, watermark, connection: self.connection)
      definitions = RecordingStudioLogs.registry.aggregations_for(log)
      return false if definitions.empty?

      definitions.all? do |definition|
        starts = definition.period.starts_overlapping(lower, upper)
        starts.any? && fresh?(definition.name, starts, watermark, connection: connection)
      end
    end

    def self.coerce_start(value)
      case value
      when Time then value.utc.change(usec: 0)
      when Date then Time.utc(value.year, value.month, value.day)
      else
        time = value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
        time.utc.change(usec: 0)
      end
    end

    def self.upsert(connection, name, period_start, status, error_message)
      format(
        UPSERT,
        table: connection.quote_table_name(table_name), name: connection.quote(name),
        start: connection.quote(period_start), status: connection.quote(status),
        error: connection.quote(error_message), finished: connection.quote(Time.current)
      )
    end

    def self.succeeded_at(connection, aggregation_name, starts)
      list = starts.map { |start| connection.quote(start) }.join(", ")
      sql = <<~SQL.squish
        SELECT finished_at FROM #{connection.quote_table_name(table_name)}
        WHERE aggregation_name = #{connection.quote(aggregation_name)}
          AND status = 'succeeded' AND period_start IN (#{list})
      SQL
      connection.select_values(sql).filter_map { |value| Retention::RawRows.coerce_time(value) }
    end
    private_class_method :upsert, :succeeded_at
  end
end
