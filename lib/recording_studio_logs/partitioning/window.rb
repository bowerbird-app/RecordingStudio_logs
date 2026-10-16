# frozen_string_literal: true

module RecordingStudioLogs
  module Partitioning
    module Window
      module_function

      def months(now: Time.now.utc, ahead: RecordingStudioLogs.configuration.months_ahead)
        cursor = now.utc.beginning_of_month.prev_month
        finish = now.utc.beginning_of_month.advance(months: ahead)
        list = []
        while cursor <= finish
          list << cursor
          cursor = cursor.next_month
        end
        list
      end
    end
  end
end
