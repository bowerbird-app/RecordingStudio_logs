# frozen_string_literal: true

module RecordingStudioLogs
  module Partitioning
    module Names
      MAX_LENGTH = 63
      SUFFIX_LENGTH = "_2000_01".length

      module_function

      def partition(table_name, month)
        name = "#{table_name}_#{month.utc.strftime('%Y_%m')}"
        raise InvalidRegistration, "#{name} exceeds #{MAX_LENGTH} characters" if name.length > MAX_LENGTH

        name
      end

      def check_table!(table_name)
        return if table_name.to_s.length + SUFFIX_LENGTH <= MAX_LENGTH

        raise InvalidRegistration, "#{table_name} is too long for a monthly partition name"
      end
    end
  end
end
