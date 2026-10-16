# frozen_string_literal: true

module RecordingStudioLogs
  module Schema
    TableInspection = Data.define(
      :table_name, :partitioned, :partition_key, :columns, :primary_key, :unique_indexes, :foreign_keys,
      :inbound_foreign_keys
    )
    UniqueIndex = Data.define(:name, :columns)
    ForeignKey = Data.define(:name, :column, :to_table)
    Compatibility = Data.define(:compatible, :problems)

    module Inspection
      module_function

      def inspect_table(table_name, connection: ActiveRecord::Base.connection)
        name = table_name.to_s
        TableInspection.new(
          table_name: name,
          partitioned: partitioned?(name, connection),
          partition_key: partition_key(name, connection),
          columns: connection.columns(name).map(&:name),
          primary_key: Array(connection.primary_keys(name)),
          unique_indexes: unique_indexes(name, connection),
          foreign_keys: outbound_keys(name, connection),
          inbound_foreign_keys: inbound_keys(name, connection)
        )
      end

      def partition_compatibility(table_name, timestamp_column:, connection: ActiveRecord::Base.connection)
        inspection = inspect_table(table_name, connection: connection)
        key = timestamp_column.to_s
        problems = []
        problems.concat(primary_key_problems(inspection, key))
        problems.concat(unique_index_problems(inspection, key))
        problems.concat(inbound_key_problems(inspection, key))
        Compatibility.new(compatible: problems.empty?, problems: problems)
      end

      def partitioned?(table_name, connection)
        connection.select_value(<<~SQL.squish).present?
          SELECT 1
          FROM pg_partitioned_table partitioned
          JOIN pg_class klass ON klass.oid = partitioned.partrelid
          JOIN pg_namespace namespace ON namespace.oid = klass.relnamespace
          WHERE namespace.nspname = current_schema()
            AND klass.relname = #{connection.quote(table_name.to_s)}
        SQL
      end

      def partition_key(table_name, connection)
        connection.select_values(<<~SQL.squish)
          SELECT attribute.attname
          FROM pg_partitioned_table partitioned
          JOIN pg_class klass ON klass.oid = partitioned.partrelid
          JOIN pg_namespace namespace ON namespace.oid = klass.relnamespace
          JOIN pg_attribute attribute
            ON attribute.attrelid = klass.oid
           AND attribute.attnum = ANY (partitioned.partattrs)
          WHERE namespace.nspname = current_schema()
            AND klass.relname = #{connection.quote(table_name.to_s)}
          ORDER BY attribute.attnum
        SQL
      end

      def unique_indexes(table_name, connection)
        connection.indexes(table_name).select(&:unique).map do |index|
          UniqueIndex.new(name: index.name, columns: index.columns.map(&:to_s))
        end
      end

      def outbound_keys(table_name, connection)
        connection.foreign_keys(table_name).map do |key|
          ForeignKey.new(name: key.name, column: key.column.to_s, to_table: key.to_table.to_s)
        end
      end

      def inbound_keys(table_name, connection)
        connection.select_all(<<~SQL.squish).map do |row|
          SELECT constraint_row.conname AS name,
                 source.relname AS from_table,
                 source_attribute.attname AS column
          FROM pg_constraint constraint_row
          JOIN pg_class target ON target.oid = constraint_row.confrelid
          JOIN pg_namespace namespace ON namespace.oid = target.relnamespace
          JOIN pg_class source ON source.oid = constraint_row.conrelid
          JOIN pg_attribute source_attribute
            ON source_attribute.attrelid = source.oid
           AND source_attribute.attnum = ANY (constraint_row.conkey)
          WHERE constraint_row.contype = 'f'
            AND namespace.nspname = current_schema()
            AND target.relname = #{connection.quote(table_name.to_s)}
        SQL
          ForeignKey.new(name: row["name"], column: row["column"], to_table: row["from_table"])
        end
      end

      def primary_key_problems(inspection, key)
        return [] if inspection.primary_key.include?(key)

        ["primary key does not include #{key}"]
      end

      def unique_index_problems(inspection, key)
        inspection.unique_indexes.filter_map do |index|
          next if index.columns.include?(key)

          "unique index #{index.name} does not include #{key}"
        end
      end

      def inbound_key_problems(inspection, key)
        return [] if inspection.inbound_foreign_keys.empty? || inspection.primary_key.include?(key)

        inspection.inbound_foreign_keys.map do |foreign_key|
          "foreign key #{foreign_key.name} from #{foreign_key.to_table} cannot follow a partition key of #{key}"
        end
      end
    end
  end
end
