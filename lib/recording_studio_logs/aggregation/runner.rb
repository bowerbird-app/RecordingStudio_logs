# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    class Runner
      def self.call(aggregation, day:, connection: ActiveRecord::Base.connection)
        new(aggregation, day, connection).call
      end

      def initialize(aggregation, day, connection)
        @aggregation = aggregation
        @day = day.to_date
        @connection = connection
      end

      def call
        refuse_dormant!
        refuse_missing_table!
        replace_day
      rescue NotReady
        raise
      rescue StandardError => e
        record_failure(e)
        raise
      end

      private

      attr_reader :aggregation, :day, :connection

      def refuse_dormant!
        raise NotReady, "#{aggregation.name} is waiting for its gems" if aggregation.dormant?
      end

      def refuse_missing_table!
        return if aggregation.summary_ready?

        error = NotReady.new("#{aggregation.name} summary table is missing")
        record_failure(error)
        raise error
      end

      def replace_day
        Lock.with(connection, Lock.key(aggregation.name, day)) do
          delete_day
          insert_day
          AggregationRun.record!(
            aggregation_name: aggregation.name, day: day, status: "succeeded", connection: connection
          )
        end
      end

      def delete_day
        sql = "DELETE FROM #{summary_table} WHERE #{quote(:day)} = #{connection.quote(day)}"
        connection.execute(sql)
      end

      def insert_day
        sql = statement.sql
        connection.execute(ActiveRecord::Base.sanitize_sql_array([sql, *statement.binds]))
      end

      def statement
        @statement ||= Statement.new(aggregation, day, connection)
      end

      def record_failure(error)
        AggregationRun.record!(
          aggregation_name: aggregation.name,
          day: day,
          status: "failed",
          error_message: error.message,
          connection: connection
        )
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
