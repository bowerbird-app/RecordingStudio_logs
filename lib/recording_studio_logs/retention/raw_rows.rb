# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    module RawRows
      module_function

      def newest(connection, log, lower, upper)
        stamp_columns(log).filter_map { |column| max_stamp(connection, log, column, lower, upper) }.max
      end

      def oldest_day(connection, log, cutoff)
        value = connection.select_value(min_sql(connection, log, cutoff))
        value&.to_date
      end

      def delete_expired(connection, log, cutoff)
        connection.execute(delete_expired_sql(connection, log, cutoff))
      end

      def days_for(connection, table_name, time_column, root_column, root_recording_id)
        time = connection.quote_column_name(time_column)
        sql = <<~SQL.squish
          SELECT DISTINCT #{time}::date FROM #{quoted(connection, table_name)}
          WHERE #{match(connection, root_column, root_recording_id)}
        SQL
        connection.select_values(sql).map(&:to_date)
      end

      def count(connection, table_name, column, root_recording_id)
        table = quoted(connection, table_name)
        where = match(connection, column, root_recording_id)
        connection.select_value("SELECT COUNT(*) FROM #{table} WHERE #{where}").to_i
      end

      def delete(connection, table_name, column, root_recording_id)
        sql = "DELETE FROM #{quoted(connection, table_name)} WHERE #{match(connection, column, root_recording_id)}"
        connection.exec_delete(sql, "Owner deletion")
      end

      def stamp_columns(log)
        columns = [log.timestamp_column.to_s]
        columns << "created_at" if log.model.column_names.include?("created_at")
        columns
      end

      def max_stamp(connection, log, column, lower, upper)
        quoted = connection.quote_column_name(column)
        sql = "SELECT MAX(#{quoted}) FROM #{quoted_table(connection, log)} #{bounds(connection, log, lower, upper)}"
        coerce_time(connection.select_value(sql.squish))
      end

      def bounds(connection, log, lower, upper)
        time = connection.quote_column_name(log.timestamp_column)
        parts = []
        parts << "#{time} >= #{connection.quote(lower)}" if lower
        parts << "#{time} < #{connection.quote(upper)}" if upper
        return "" if parts.empty?

        "WHERE #{parts.join(' AND ')}"
      end

      def min_sql(connection, log, cutoff)
        time = connection.quote_column_name(log.timestamp_column)
        <<~SQL.squish
          SELECT MIN(#{time}) FROM #{quoted_table(connection, log)}
          WHERE #{time} < #{connection.quote(cutoff)}
        SQL
      end

      def delete_expired_sql(connection, log, cutoff)
        time = connection.quote_column_name(log.timestamp_column)
        "DELETE FROM #{quoted_table(connection, log)} WHERE #{time} < #{connection.quote(cutoff)}"
      end

      def quoted_table(connection, log)
        quoted(connection, log.table_name)
      end

      def quoted(connection, table_name)
        connection.quote_table_name(table_name)
      end

      def match(connection, column, root_recording_id)
        "#{connection.quote_column_name(column)} = #{connection.quote(root_recording_id)}"
      end

      def coerce_time(value)
        return value if value.is_a?(Time)
        return if value.blank?

        Time.find_zone!("UTC").parse(value.to_s)
      end
    end
  end
end
