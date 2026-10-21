# frozen_string_literal: true

module RecordingStudioLogs
  # Helpers for partitioned log tables and the summary uniqueness index.
  module Schema # rubocop:disable Metrics/ModuleLength
    module_function

    def partitioned_log(table_name, timestamp_column:, connection: ActiveRecord::Base.connection)
      quoted_time = connection.quote_column_name(timestamp_column)
      connection.create_table(table_name, id: false, options: "PARTITION BY RANGE (#{quoted_time})") do |definition|
        definition.uuid :id, null: false, default: -> { "gen_random_uuid()" }
        definition.datetime timestamp_column, null: false
        definition.datetime :arrived_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
        yield definition if block_given?
      end
      add_partition_primary_key(connection, table_name, quoted_time)
    end

    def summary_index(table_name, columns, name:, connection: ActiveRecord::Base.connection)
      connection.add_index(
        table_name,
        columns,
        unique: true,
        nulls_not_distinct: true,
        name: name
      )
    end

    def root_and_time_index(table_name, root_column:, timestamp_column:, name: nil,
                            connection: ActiveRecord::Base.connection)
      columns = [root_column, timestamp_column]
      connection.add_index(table_name, columns, name: name || index_name(table_name, columns))
    end

    def inspect_table(...)
      Inspection.inspect_table(...)
    end

    def partition_compatibility(...)
      Inspection.partition_compatibility(...)
    end

    def index_name(table_name, columns)
      "index_#{table_name}_on_#{columns.join('_')}"[0, 63]
    end

    def install_runs!(connection = ActiveRecord::Base.connection)
      install_aggregation_runs!(connection)
      install_maintenance_runs!(connection)
    end

    def add_partition_primary_key(connection, table_name, quoted_time)
      quoted_table = connection.quote_table_name(table_name)
      quoted_id = connection.quote_column_name("id")
      connection.execute("ALTER TABLE #{quoted_table} ADD PRIMARY KEY (#{quoted_id}, #{quoted_time})")
    end

    def install_aggregation_runs!(connection)
      table = :recording_studio_logs_aggregation_runs
      unless connection.table_exists?(table)
        connection.create_table(table, id: :uuid) { |definition| aggregation_columns(definition) }
        connection.add_index table, %i[aggregation_name period_start],
                             unique: true, name: "index_rs_logs_aggregation_runs_on_name_and_period"
      end
      upgrade_aggregation_runs!(connection)
    end

    def upgrade_aggregation_runs!(connection = ActiveRecord::Base.connection) # rubocop:disable Metrics/MethodLength
      table = :recording_studio_logs_aggregation_runs
      return unless connection.table_exists?(table)
      return if connection.column_exists?(table, :period_start)
      return unless connection.column_exists?(table, :day)

      connection.add_column table, :period_start, :datetime
      quoted = connection.quote_table_name(table)
      connection.execute("UPDATE #{quoted} SET period_start = (day::timestamp AT TIME ZONE 'UTC')")
      connection.change_column_null table, :period_start, false
      if connection.index_name_exists?(table, "index_rs_logs_aggregation_runs_on_name_and_day")
        connection.remove_index table, name: "index_rs_logs_aggregation_runs_on_name_and_day"
      end
      connection.remove_column table, :day
      connection.add_index table, %i[aggregation_name period_start],
                           unique: true, name: "index_rs_logs_aggregation_runs_on_name_and_period"
    end

    def downgrade_aggregation_runs!(connection = ActiveRecord::Base.connection) # rubocop:disable Metrics/MethodLength
      table = :recording_studio_logs_aggregation_runs
      return unless connection.table_exists?(table)
      return unless connection.column_exists?(table, :period_start)
      return if connection.column_exists?(table, :day)

      connection.add_column table, :day, :date
      quoted = connection.quote_table_name(table)
      connection.execute("UPDATE #{quoted} SET day = (period_start AT TIME ZONE 'UTC')::date")
      connection.change_column_null table, :day, false
      if connection.index_name_exists?(table, "index_rs_logs_aggregation_runs_on_name_and_period")
        connection.remove_index table, name: "index_rs_logs_aggregation_runs_on_name_and_period"
      end
      connection.remove_column table, :period_start
      connection.add_index table, %i[aggregation_name day],
                           unique: true, name: "index_rs_logs_aggregation_runs_on_name_and_day"
    end

    def install_maintenance_runs!(connection)
      return if connection.table_exists?(:recording_studio_logs_maintenance_runs)

      connection.create_table(:recording_studio_logs_maintenance_runs, id: :uuid) { |table| maintenance_columns(table) }
      connection.add_index :recording_studio_logs_maintenance_runs, %i[task subject finished_at],
                           name: "index_rs_logs_maintenance_runs_on_task_and_subject"
    end

    def aggregation_columns(table)
      table.string :aggregation_name, null: false
      table.datetime :period_start, null: false
      table.string :status, null: false
      table.text :error_message
      table.datetime :finished_at
      table.timestamps
    end

    def maintenance_columns(table)
      table.string :task, null: false
      table.string :subject, null: false
      table.string :status, null: false
      table.text :details
      table.datetime :finished_at, null: false
      table.timestamps
    end
  end
end
