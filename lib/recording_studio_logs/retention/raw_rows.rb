# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    module RawRows
      module_function

      def newest(connection, log, lower, upper)
        stamp_columns(log).filter_map { |column| max_stamp(connection, log, column, lower, upper) }.max
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
        %w[arrived_at created_at].each { |name| columns << name if log.model.column_names.include?(name) }
        columns
      end

      def expired_days(connection, log, cutoff)
        time = connection.quote_column_name(log.timestamp_column)
        sql = "SELECT DISTINCT #{utc_day(time)} FROM #{quoted_table(connection, log)} " \
              "WHERE #{time} < #{connection.quote(cutoff)}"
        connection.select_values(sql).map(&:to_date)
      end

      def newest_for_days(connection, log, cutoff, days)
        return if days.blank?

        stamp_columns(log).filter_map { |column| max_on_days(connection, log, column, cutoff, days) }.max
      end

      def delete_days(connection, log, cutoff, days)
        return if days.blank?

        time = connection.quote_column_name(log.timestamp_column)
        list = days.map { |day| connection.quote(day) }.join(", ")
        sql = "DELETE FROM #{quoted_table(connection, log)} WHERE #{time} < #{connection.quote(cutoff)} " \
              "AND #{utc_day(time)} IN (#{list})"
        connection.execute(sql)
      end

      def max_on_days(connection, log, column, cutoff, days)
        time = connection.quote_column_name(log.timestamp_column)
        quoted = connection.quote_column_name(column)
        list = days.map { |day| connection.quote(day) }.join(", ")
        sql = "SELECT MAX(#{quoted}) FROM #{quoted_table(connection, log)} " \
              "WHERE #{time} < #{connection.quote(cutoff)} AND #{utc_day(time)} IN (#{list})"
        coerce_time(connection.select_value(sql))
      end

      def utc_day(quoted_time)
        "((#{quoted_time} AT TIME ZONE 'UTC') AT TIME ZONE 'UTC')::date"
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
