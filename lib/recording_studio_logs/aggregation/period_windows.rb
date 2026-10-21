# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    module PeriodWindows
      module_function

      def overlapping_starts(period, lower, upper)
        lower = period.utc_time(lower)
        upper = period.utc_time(upper)
        return [] unless lower < upper

        collect_starts(period, period.start_for(lower), lower, upper)
      end

      def collect_starts(period, cursor, lower, upper)
        starts = []
        while cursor < upper
          starts << cursor if period.finish(cursor) > lower
          nxt = period.finish(cursor)
          break if nxt <= cursor

          cursor = nxt
        end
        starts
      end
    end
  end
end
