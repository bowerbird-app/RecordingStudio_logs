# frozen_string_literal: true

module RecordingStudioLogs
  module Partitioning
    Partition = Data.define(:name, :lower, :upper, :estimated_rows, :bytes)

    module Catalog
      module_function

      def list(table_name, connection = ActiveRecord::Base.connection)
        connection.select_all(list_sql(connection, table_name)).map { |row| build(row) }
      end

      def exists?(table_name, partition_name, connection = ActiveRecord::Base.connection)
        list(table_name, connection).any? { |partition| partition.name == partition_name }
      end

      def create(parent, partition_name, lower, upper, connection = ActiveRecord::Base.connection)
        sql = <<~SQL.squish
          CREATE TABLE IF NOT EXISTS #{connection.quote_table_name(partition_name)}
          PARTITION OF #{connection.quote_table_name(parent)}
          FOR VALUES FROM (#{connection.quote(lower)}) TO (#{connection.quote(upper)})
        SQL
        connection.execute(sql)
      end

      def drop(partition_name, connection = ActiveRecord::Base.connection)
        connection.execute("DROP TABLE IF EXISTS #{connection.quote_table_name(partition_name)}")
      end

      LIST_SQL = <<~SQL.squish.freeze
        SELECT child.relname AS name,
               pg_get_expr(child.relpartbound, child.oid) AS bounds,
               child.reltuples AS estimated_rows,
               pg_total_relation_size(child.oid) AS bytes
        FROM pg_inherits
        JOIN pg_class parent ON parent.oid = pg_inherits.inhparent
        JOIN pg_class child ON child.oid = pg_inherits.inhrelid
        JOIN pg_namespace namespace ON namespace.oid = parent.relnamespace
        WHERE namespace.nspname = current_schema()
          AND parent.relname = TABLE_NAME
        ORDER BY child.relname
      SQL

      def list_sql(connection, table_name)
        LIST_SQL.sub("TABLE_NAME", connection.quote(table_name))
      end

      def build(row)
        lower, upper = bounds(row["bounds"])
        Partition.new(
          name: row["name"],
          lower: lower,
          upper: upper,
          estimated_rows: estimate(row["estimated_rows"]),
          bytes: row["bytes"].to_i
        )
      end

      def bounds(expression)
        matches = expression.to_s.scan(/'([^']+)'/)
        [parse_time(matches[0]&.first), parse_time(matches[1]&.first)]
      end

      def parse_time(value)
        return if value.blank?

        Time.find_zone!("UTC").parse(value)
      end

      def estimate(value)
        number = value.to_f
        return if number.negative?

        number.round
      end
    end
  end
end
