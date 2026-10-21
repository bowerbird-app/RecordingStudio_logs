# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    WindowScope = Data.define(:connection, :log, :column, :cutoff, :lower, :upper)

    module WindowRows
      module_function

      def max(scope)
        RawRows.coerce_time(scope.connection.select_value(max_sql(scope)))
      end

      def max_sql(scope)
        time = scope.connection.quote_column_name(scope.log.timestamp_column)
        quoted = scope.connection.quote_column_name(scope.column)
        table = RawRows.quoted_table(scope.connection, scope.log)
        "SELECT MAX(#{quoted}) FROM #{table} WHERE #{window_bounds(scope, time)}"
      end

      def window_bounds(scope, time)
        "#{time} < #{scope.connection.quote(scope.cutoff)} " \
          "AND #{time} >= #{scope.connection.quote(scope.lower)} " \
          "AND #{time} < #{scope.connection.quote(scope.upper)}"
      end

      def newest_before(connection, log, cutoff, lower, upper)
        RawRows.stamp_columns(log).filter_map do |column|
          max(WindowScope.new(connection, log, column, cutoff, lower, upper))
        end.max
      end

      def expired_bounds(connection, log, cutoff)
        time = connection.quote_column_name(log.timestamp_column)
        sql = "SELECT MIN(#{time}), MAX(#{time}) FROM #{RawRows.quoted_table(connection, log)} " \
              "WHERE #{time} < #{connection.quote(cutoff)}"
        row = connection.select_rows(sql).first
        return if row.blank? || row[0].blank?

        [RawRows.coerce_time(row[0]), RawRows.coerce_time(row[1])]
      end

      def delete_windows(connection, log, cutoff, windows)
        return if windows.blank?

        time = connection.quote_column_name(log.timestamp_column)
        clauses = windows.map do |lower, upper|
          "(#{time} >= #{connection.quote(lower)} AND #{time} < #{connection.quote(upper)})"
        end
        sql = "DELETE FROM #{RawRows.quoted_table(connection, log)} WHERE #{time} < #{connection.quote(cutoff)} " \
              "AND (#{clauses.join(' OR ')})"
        connection.execute(sql)
      end
    end
  end
end
