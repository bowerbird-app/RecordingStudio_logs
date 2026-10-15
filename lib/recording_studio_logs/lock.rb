# frozen_string_literal: true

require "zlib"

module RecordingStudioLogs
  module Lock
    module_function

    def with(connection, name)
      key = Zlib.crc32(name.to_s)
      connection.transaction do
        connection.execute("SELECT pg_advisory_xact_lock(#{key})")
        yield
      end
    end
  end
end
