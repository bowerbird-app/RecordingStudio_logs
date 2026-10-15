# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    class Statement
      attr_reader :binds

      def initialize(aggregation, day, connection)
        @aggregation = aggregation
        @day = day
        @connection = connection
        @log = aggregation.log
        @binds = []
      end

      def sql
        <<~SQL.squish
          INSERT INTO #{quote_table(summary_table)} (#{insert_list})
          SELECT gen_random_uuid(), #{select_list}
          FROM #{quote_table(source_table)}
          WHERE #{where_sql}
          #{group_sql}
        SQL
      end

      private

      attr_reader :aggregation, :day, :connection, :log

      def insert_list
        columns = ["id", "day", *group_names, *measurement_names, "created_at", "updated_at"]
        columns.map { |column| quote(column) }.join(", ")
      end

      def select_list
        parts = [bind(day), *group_names.map { |column| quote(column) }]
        parts.concat(aggregation.measurements.map { |measurement| measurement.sql(connection) })
        parts << "CURRENT_TIMESTAMP" << "CURRENT_TIMESTAMP"
        parts.join(", ")
      end

      def where_sql
        clauses = window_clauses
        aggregation.filter.each { |column, value| clauses << "#{quote(column)} = #{bind(value)}" }
        clauses.join(" AND ")
      end

      def window_clauses
        start_at, finish_at = window
        [
          "#{quote(log.timestamp_column)} >= #{bind(start_at)}",
          "#{quote(log.timestamp_column)} < #{bind(finish_at)}"
        ]
      end

      def group_sql
        return "" if group_names.empty?

        "GROUP BY #{group_names.map { |column| quote(column) }.join(', ')}"
      end

      def window
        start_at = Time.utc(day.year, day.month, day.day)
        [start_at, start_at + 1.day]
      end

      def group_names
        aggregation.group_by
      end

      def measurement_names
        aggregation.measurements.map(&:name)
      end

      def summary_table
        aggregation.summary_model.table_name
      end

      def source_table
        log.model.table_name
      end

      def bind(value)
        binds << value
        "?"
      end

      def quote(column)
        connection.quote_column_name(column)
      end

      def quote_table(name)
        connection.quote_table_name(name)
      end
    end
  end
end
