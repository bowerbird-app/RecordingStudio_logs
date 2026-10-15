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

    def key(aggregation_name, day)
      "aggregation:#{aggregation_name}:#{day}"
    end

    def names_for(definitions, days)
      definitions.flat_map { |definition| days.map { |day| key(definition.name, day) } }
    end
  end
end
