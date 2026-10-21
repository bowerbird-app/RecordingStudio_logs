# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    class Scheduler
      def self.aggregate_day(day, connection = ActiveRecord::Base.connection)
        new(connection).aggregate_day(day)
      end

      def self.aggregate_due(now = Time.now.utc, connection = ActiveRecord::Base.connection)
        new(connection).aggregate_due(now)
      end

      def self.aggregate_period(name, period_start, connection = ActiveRecord::Base.connection)
        new(connection).aggregate_period(name, period_start)
      end

      def self.backfill(name, from:, to:, connection: ActiveRecord::Base.connection)
        new(connection).backfill(name, from, to)
      end

      def self.reconcile(connection = ActiveRecord::Base.connection, now: nil, today: nil)
        stamp = now || today || Time.now.utc
        new(connection).reconcile(stamp)
      end

      def initialize(connection)
        @connection = connection
        @failures = []
      end

      def aggregate_day(day)
        start = AggregationRun.coerce_start(day)
        runnable.select(&:calendar_day?).each { |definition| run(definition, start) }
        raise_failures!
      end

      def aggregate_due(now)
        runnable.each do |definition|
          definition.scheduled_starts(now).each { |start| run(definition, start) }
        end
        raise_failures!
      end

      def aggregate_period(name, period_start)
        run(RecordingStudioLogs.registry.aggregation(name), period_start)
        raise_failures!
      end

      def backfill(name, from, to)
        definition = RecordingStudioLogs.registry.aggregation(name)
        definition.period.each_start(from, to) { |start| run(definition, start) }
        raise_failures!
      end

      def reconcile(now)
        runnable.each do |definition|
          definition.reconciliation_starts(now).each { |start| run(definition, start) }
        end
        raise_failures!
      end

      private

      attr_reader :connection, :failures

      def runnable
        RecordingStudioLogs.aggregations.reject(&:dormant?)
      end

      def run(definition, period_start)
        Runner.call(definition, period_start: period_start, connection: connection)
      rescue StandardError => e
        failures << e
      end

      def raise_failures!
        error = failures.shift
        failures.clear
        raise error if error
      end
    end
  end
end
