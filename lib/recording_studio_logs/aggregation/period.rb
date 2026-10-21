# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    class Period # rubocop:disable Metrics/ClassLength
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
        time = utc_time(value)
        case kind
        when :hour then hour_start(time)
        when :day then day_start(time)
        when :week then week_start(time)
        when :month then month_start(time)
        end
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

      def starts_overlapping(lower, upper) # rubocop:disable Metrics/MethodLength
        lower = utc_time(lower)
        upper = utc_time(upper)
        return [] unless lower < upper

        starts = []
        cursor = start_for(lower)
        while cursor < upper
          starts << cursor if finish(cursor) > lower
          nxt = finish(cursor)
          break if nxt <= cursor

          cursor = nxt
        end
        starts
      end

      def window(start)
        start = start_for(start)
        [start, finish(start)]
      end

      private

      def validate!
        raise InvalidRegistration, "period must be :hour, :day, :week, or :month" unless KINDS.include?(kind)
        raise InvalidRegistration, "every must be a positive integer" unless every.positive?
        return unless kind == :hour
        return if (24 % every).zero?

        raise InvalidRegistration, "hourly every must divide 24"
      end

      def hour_start(time)
        hour = (time.hour / every) * every
        Time.utc(time.year, time.month, time.day, hour)
      end

      def day_start(time)
        date = time.to_date
        offset = (date - DAY_EPOCH).to_i
        aligned = date - (offset % every)
        Time.utc(aligned.year, aligned.month, aligned.day)
      end

      def week_start(time) # rubocop:disable Metrics/AbcSize
        date = time.to_date
        monday = date - (date.cwday - 1)
        weeks = ((monday - WEEK_EPOCH).to_i / 7)
        aligned = WEEK_EPOCH + (((weeks / every) * every) * 7)
        Time.utc(aligned.year, aligned.month, aligned.day)
      end

      def month_start(time)
        index = ((time.year - 1970) * 12) + (time.month - 1)
        aligned = (index / every) * every
        year = 1970 + (aligned / 12)
        month = (aligned % 12) + 1
        Time.utc(year, month, 1)
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
    end
  end
end
