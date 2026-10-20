# frozen_string_literal: true

module RecordingStudioLogs
  module Partitioning
    TableStat = Data.define(:rows, :bytes)

    module TableStats
      module_function

      def call(table_name, partitioned:, connection: ActiveRecord::Base.connection)
        partitioned ? partitioned_stat(table_name, connection) : table_stat(table_name, connection)
      end

      def partitioned_stat(table_name, connection)
        parts = Catalog.list(table_name, connection)
        TableStat.new(rows: parts.sum { |part| part.estimated_rows.to_i }, bytes: parts.sum(&:bytes))
      end

      def table_stat(table_name, connection)
        row = connection.select_one(<<~SQL.squish)
          SELECT pg_class.reltuples AS estimated_rows, pg_total_relation_size(pg_class.oid) AS bytes
          FROM pg_class
          JOIN pg_namespace ON pg_namespace.oid = pg_class.relnamespace
          WHERE pg_namespace.nspname = current_schema()
            AND pg_class.relname = #{connection.quote(table_name.to_s)}
        SQL
        return TableStat.new(rows: nil, bytes: nil) if row.nil?

        TableStat.new(rows: Catalog.estimate(row["estimated_rows"]), bytes: row["bytes"].to_i)
      end
    end
  end
end
