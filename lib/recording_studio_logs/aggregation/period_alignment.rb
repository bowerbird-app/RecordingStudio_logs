# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    module PeriodAlignment
      module_function

      def start(kind, every, time)
        case kind
        when :hour then hour_start(every, time)
        when :day then day_start(every, time)
        when :week then week_start(every, time)
        when :month then month_start(every, time)
        end
      end

      def hour_start(every, time)
        hours = ((time - Period::HOUR_EPOCH) / 3600).to_i
        Period::HOUR_EPOCH + ((hours / every) * every * 3600)
      end

      def day_start(every, time)
        date = time.to_date
        aligned = date - ((date - Period::DAY_EPOCH).to_i % every)
        Time.utc(aligned.year, aligned.month, aligned.day)
      end

      def week_start(every, time)
        monday = time.to_date - (time.to_date.cwday - 1)
        weeks = ((monday - Period::WEEK_EPOCH).to_i / 7)
        aligned = Period::WEEK_EPOCH + (((weeks / every) * every) * 7)
        Time.utc(aligned.year, aligned.month, aligned.day)
      end

      def month_start(every, time)
        index = ((time.year - 1970) * 12) + (time.month - 1)
        aligned = (index / every) * every
        Time.utc(1970 + (aligned / 12), (aligned % 12) + 1, 1)
      end
    end
  end
end
