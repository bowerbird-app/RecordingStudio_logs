# frozen_string_literal: true

require "zlib"

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
      names.map { |name| Zlib.crc32(name.to_s) }.uniq.sort.each do |key|
        connection.execute("SELECT pg_advisory_xact_lock(#{key})")
      end
    end

    def key(aggregation_name, day)
      "aggregation:#{aggregation_name}:#{day}"
    end

    def names_for(definitions, days)
      definitions.flat_map { |definition| days.map { |day| key(definition.name, day) } }
    end
  end
end
