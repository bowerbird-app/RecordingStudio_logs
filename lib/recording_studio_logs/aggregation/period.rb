# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    class Period
      KINDS = %i[hour day week month].freeze
      DAY_EPOCH = Date.new(1970, 1, 1)
      WEEK_EPOCH = Date.new(1970, 1, 5)

      attr_reader :kind, :every

      def initialize(kind, every)
        @kind = kind.to_sym
        @every = Integer(every)
        validate!
      end

      def start_for(value)
        PeriodAlignment.start(kind, every, utc_time(value))
      end

      def finish(start)
        start = utc_time(start)
        case kind
        when :hour then start + every.hours
        when :day then start + every.days
        when :week then start + (every * 7).days
        when :month then start + every.months
        end
      end

      def previous(start)
        start_for(utc_time(start) - 1.second)
      end

      def closed?(start, now)
        finish(start) <= utc_time(now)
      end

      def each_start(from, to)
        cursor = start_for(from)
        last = start_for(to)
        while cursor <= last
          yield cursor
          nxt = finish(cursor)
          break if nxt <= cursor

          cursor = nxt
        end
      end

      def starts_overlapping(lower, upper)
        PeriodWindows.overlapping_starts(self, lower, upper)
      end

      def window(start)
        start = start_for(start)
        [start, finish(start)]
      end

      def utc_time(value)
        case value
        when Time then value.utc
        when Date then Time.utc(value.year, value.month, value.day)
        else
          time = value.respond_to?(:to_time) ? value.to_time : Time.parse(value.to_s)
          time.utc
        end
      end

      private

      def validate!
        raise InvalidRegistration, "period must be :hour, :day, :week, or :month" unless KINDS.include?(kind)
        raise InvalidRegistration, "every must be a positive integer" unless every.positive?
        return unless kind == :hour
        return if (24 % every).zero?

        raise InvalidRegistration, "hourly every must divide 24"
      end
    end
  end
end
