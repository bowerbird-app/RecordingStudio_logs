# frozen_string_literal: true

module RecordingStudioLogs
  module Schema
    module AggregationRunsUpgrade
      module_function

      TABLE = :recording_studio_logs_aggregation_runs

      def upgrade!(connection = ActiveRecord::Base.connection)
        return unless needs_upgrade?(connection)

        connection.add_column TABLE, :period_start, :datetime
        copy_day_to_period_start(connection)
        connection.change_column_null TABLE, :period_start, false
        swap_index(connection, "index_rs_logs_aggregation_runs_on_name_and_day",
                   %i[aggregation_name period_start], "index_rs_logs_aggregation_runs_on_name_and_period")
        connection.remove_column TABLE, :day
      end

      def downgrade!(connection = ActiveRecord::Base.connection)
        return unless needs_downgrade?(connection)

        connection.add_column TABLE, :day, :date
        copy_period_start_to_day(connection)
        connection.change_column_null TABLE, :day, false
        swap_index(connection, "index_rs_logs_aggregation_runs_on_name_and_period",
                   %i[aggregation_name day], "index_rs_logs_aggregation_runs_on_name_and_day")
        connection.remove_column TABLE, :period_start
      end

      def needs_upgrade?(connection)
        connection.table_exists?(TABLE) &&
          !connection.column_exists?(TABLE, :period_start) &&
          connection.column_exists?(TABLE, :day)
      end

      def needs_downgrade?(connection)
        connection.table_exists?(TABLE) &&
          connection.column_exists?(TABLE, :period_start) &&
          !connection.column_exists?(TABLE, :day)
      end

      def copy_day_to_period_start(connection)
        quoted = connection.quote_table_name(TABLE)
        connection.execute("UPDATE #{quoted} SET period_start = (day::timestamp)")
      end

      def copy_period_start_to_day(connection)
        quoted = connection.quote_table_name(TABLE)
        connection.execute("UPDATE #{quoted} SET day = (period_start AT TIME ZONE 'UTC')::date")
      end

      def swap_index(connection, old_name, columns, new_name)
        connection.remove_index TABLE, name: old_name if connection.index_name_exists?(TABLE, old_name)
        connection.add_index TABLE, columns, unique: true, name: new_name
      end
    end
  end
end
