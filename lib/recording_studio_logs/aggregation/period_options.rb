# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    class PeriodOptions
      COUNTS = %i[scheduled sync async].freeze

      attr_reader :period, :period_column, :count, :count_after, :include_current

      def self.parse(**options)
        new(options)
      end

      def initialize(options)
        @period = Period.new(*coerce_period(options[:interval], options[:period], options[:every]))
        @period_column = options[:period_column].to_sym
        @count = options[:count].to_sym
        @count_after = normalize_wait(options[:count_after])
        @include_current = options[:include_current]
        validate!
      end

      def calendar_day?
        period.kind == :day && period.every == 1 && period_column == :day
      end

      def live_count?
        count != :scheduled
      end

      def scheduled_starts(now)
        now = now.to_time.utc
        current = period.start_for(now)
        closed_and_current(now, current, period.previous(current))
      end

      def reconciliation_starts(now)
        walk_back(period.previous(period.start_for(now)), RecordingStudioLogs.configuration.reconciliation_days)
      end

      def summary_period_key(period_start, date_column:)
        date_column ? period_start.to_date : period_start
      end

      def validate_column!(definition)
        return unless definition.summary_ready?

        column = definition.summary_model.columns_hash[period_column.to_s]
        raise InvalidRegistration, "#{definition.name} summary needs #{period_column}" if column.nil?
        return unless period.kind == :hour && column.type == :date

        raise InvalidRegistration, "hour periods need a datetime #{period_column} column"
      end

      private

      def closed_and_current(now, current, closed)
        starts = []
        starts << closed if now >= period.finish(closed) + count_after
        starts << current if include_current
        starts.uniq
      end

      def walk_back(cursor, count)
        starts = []
        count.times do
          starts << cursor
          cursor = period.previous(cursor)
        end
        starts
      end

      def coerce_period(interval, period, every)
        period = (period || :day).to_sym
        check_interval!(interval, period) if interval
        [period, every]
      end

      def check_interval!(interval, period)
        unless interval.to_sym == :daily
          raise InvalidRegistration, "only daily interval is supported; use period: :hour"
        end
        raise InvalidRegistration, "interval: :daily cannot combine with period: #{period}" unless period == :day
      end

      def normalize_wait(value)
        duration = value.is_a?(Numeric) ? value.seconds : value
        unless duration.respond_to?(:to_i) && duration.to_i >= 0
          raise InvalidRegistration, "count_after must be a duration of zero or more"
        end

        duration
      end

      def validate!
        raise InvalidRegistration, "count must be :scheduled, :sync, or :async" unless COUNTS.include?(count)
        return if [true, false].include?(include_current)

        raise InvalidRegistration, "include_current must be true or false"
      end
    end
  end
end
