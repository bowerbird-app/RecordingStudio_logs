# frozen_string_literal: true

module RecordingStudioLogs
  module Cutover
    CopyResult = Data.define(:inserted)
    Validation = Data.define(:source_count, :destination_count) do
      def matched?
        source_count == destination_count
      end
    end

    module_function

    def copy(from:, to:, columns:, connection: ActiveRecord::Base.connection)
      quoted = columns.map { |column| connection.quote_column_name(column) }.join(", ")
      sql = <<~SQL.squish
        INSERT INTO #{connection.quote_table_name(to)} (#{quoted})
        SELECT #{quoted} FROM #{connection.quote_table_name(from)}
        ON CONFLICT DO NOTHING
      SQL
      result = connection.execute(sql)
      CopyResult.new(inserted: result.cmd_tuples)
    end

    def validate(from:, to:, connection: ActiveRecord::Base.connection)
      Validation.new(
        source_count: count(from, connection),
        destination_count: count(to, connection)
      )
    end

    def add_root_column(table_name, column: :root_recording_id, connection: ActiveRecord::Base.connection)
      return if connection.column_exists?(table_name, column)

      connection.add_column(table_name, column, :uuid)
    end

    def backfill_root(table_name, recordings_table: "recording_studio_recordings",
                      recording_column: :recording_id, root_column: :root_recording_id,
                      connection: ActiveRecord::Base.connection)
      sql = <<~SQL.squish
        UPDATE #{connection.quote_table_name(table_name)} AS logs
        SET #{connection.quote_column_name(root_column)} = recordings.root_recording_id
        FROM #{connection.quote_table_name(recordings_table)} AS recordings
        WHERE logs.#{connection.quote_column_name(recording_column)} = recordings.id
          AND logs.#{connection.quote_column_name(root_column)} IS NULL
      SQL
      connection.execute(sql)
    end

    def count(table_name, connection)
      connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table_name)}").to_i
    end
  end
end
