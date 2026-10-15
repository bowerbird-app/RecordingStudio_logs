# frozen_string_literal: true

module RecordingStudioLogs
  # Helpers for partitioned log tables and the summary uniqueness index.
  module Schema
    module_function

    def partitioned_log(table_name, timestamp_column:, connection: ActiveRecord::Base.connection)
      quoted_time = connection.quote_column_name(timestamp_column)
      connection.create_table(table_name, id: false, options: "PARTITION BY RANGE (#{quoted_time})") do |definition|
        definition.uuid :id, null: false, default: -> { "gen_random_uuid()" }
        definition.datetime timestamp_column, null: false
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
      return if connection.table_exists?(:recording_studio_logs_aggregation_runs)

      connection.create_table(:recording_studio_logs_aggregation_runs, id: :uuid) { |table| aggregation_columns(table) }
      connection.add_index :recording_studio_logs_aggregation_runs, %i[aggregation_name day],
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
      table.date :day, null: false
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
