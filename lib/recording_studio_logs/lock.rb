# frozen_string_literal: true

require "digest"

module RecordingStudioLogs
  module Lock
    module_function

    def with(connection, *names)
      connection.transaction do
        acquire(connection, *names)
        yield
      end
    end

    def acquire(connection, *names)
      names.map { |name| key_pair(name) }.uniq.sort.each do |high, low|
        connection.execute("SELECT pg_advisory_xact_lock(#{high}, #{low})")
      end
    end

    def hold_writes(connection, table_name)
      quoted = connection.quote_table_name(table_name)
      connection.execute("LOCK TABLE #{quoted} IN SHARE ROW EXCLUSIVE MODE")
    end

    def key_pair(name)
      bytes = Digest::SHA256.digest(name.to_s)
      [bytes[0, 4].unpack1("l>"), bytes[4, 4].unpack1("l>")]
    end

    def key(aggregation_name, period_start)
      "aggregation:#{aggregation_name}:#{AggregationRun.coerce_start(period_start).iso8601}"
    end

    def names_for(definitions, units)
      definitions.flat_map do |definition|
        Array(units).map { |unit| key(definition.name, definition.period.start_for(unit)) }.uniq
      end
    end

    def names_for_range(definitions, lower, upper)
      definitions.flat_map do |definition|
        definition.period.starts_overlapping(lower, upper).map { |start| key(definition.name, start) }
      end
    end
  end
end
