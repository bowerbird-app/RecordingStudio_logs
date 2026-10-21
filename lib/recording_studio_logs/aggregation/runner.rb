# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    class Runner
      def self.call(aggregation, period_start:, connection: ActiveRecord::Base.connection)
        new(aggregation, period_start, connection).call
      end

      def initialize(aggregation, period_start, connection)
        @aggregation = aggregation
        @period_start = AggregationRun.coerce_start(period_start)
        @connection = connection
      end

      def call
        refuse_dormant!
        refuse_missing_table!
        replace_period
      rescue NotReady
        raise
      rescue StandardError => e
        record_failure(e)
        raise
      end

      private

      attr_reader :aggregation, :period_start, :connection

      def refuse_dormant!
        raise NotReady, "#{aggregation.name} is waiting for its gems" if aggregation.dormant?
      end

      def refuse_missing_table!
        return if aggregation.summary_ready?

        error = NotReady.new("#{aggregation.name} summary table is missing")
        record_failure(error)
        raise error
      end

      def replace_period
        Lock.with(connection, Lock.key(aggregation.name, period_start)) do
          delete_period
          insert_period
          AggregationRun.record!(
            aggregation_name: aggregation.name, period_start: period_start, status: "succeeded",
            connection: connection
          )
        end
      end

      def delete_period
        sql = "DELETE FROM #{summary_table} WHERE #{quote(aggregation.period_column)} = #{connection.quote(period_key)}"
        connection.execute(sql)
      end

      def insert_period
        sql = statement.sql
        connection.execute(ActiveRecord::Base.sanitize_sql_array([sql, *statement.binds]))
      end

      def statement
        @statement ||= Statement.new(aggregation, period_start, connection)
      end

      def record_failure(error)
        AggregationRun.record!(
          aggregation_name: aggregation.name,
          period_start: period_start,
          status: "failed",
          error_message: error.message,
          connection: connection
        )
      end

      def period_key
        aggregation.summary_period_key(period_start)
      end

      def summary_table
        connection.quote_table_name(aggregation.summary_model.table_name)
      end

      def quote(column)
        connection.quote_column_name(column)
      end
    end
  end
end
