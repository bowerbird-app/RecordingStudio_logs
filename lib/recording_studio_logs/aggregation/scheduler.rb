# frozen_string_literal: true

module RecordingStudioLogs
  module Aggregation
    class Scheduler
      def self.aggregate_day(day, connection = ActiveRecord::Base.connection)
        new(connection).aggregate_day(day)
      end

      def self.backfill(name, from:, to:, connection: ActiveRecord::Base.connection)
        new(connection).backfill(name, from, to)
      end

      def self.reconcile(connection = ActiveRecord::Base.connection, today: Time.now.utc.to_date)
        new(connection).reconcile(today)
      end

      def initialize(connection)
        @connection = connection
        @failures = []
      end

      def aggregate_day(day)
        runnable.each { |definition| run(definition, day) }
        raise_failures!
      end

      def backfill(name, from, to)
        definition = RecordingStudioLogs.registry.aggregation(name)
        each_day(from, to) { |day| run(definition, day) }
        raise_failures!
      end

      def reconcile(today)
        each_day(today - RecordingStudioLogs.configuration.reconciliation_days, today - 1) do |day|
          aggregate_day(day)
        end
      end

      private

      attr_reader :connection, :failures

      def runnable
        RecordingStudioLogs.aggregations.reject(&:dormant?)
      end

      def run(definition, day)
        Runner.call(definition, day: day, connection: connection)
      rescue StandardError => e
        failures << e
      end

      def each_day(from, to)
        date = from.to_date
        finish = to.to_date
        while date <= finish
          yield date
          date += 1
        end
      end

      def raise_failures!
        error = failures.shift
        failures.clear
        raise error if error
      end
    end
  end
end
