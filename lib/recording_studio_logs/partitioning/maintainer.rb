# frozen_string_literal: true

module RecordingStudioLogs
  module Partitioning
    class Maintainer
      def self.call(connection = ActiveRecord::Base.connection)
        new(connection).call
      end

      def self.ensure!(model, time, connection = ActiveRecord::Base.connection)
        new(connection).ensure(model, time)
      end

      def initialize(connection)
        @connection = connection
      end

      def call
        created = []
        failures = []
        logs.each do |log|
          created.concat(maintain(log))
        rescue StandardError => e
          failures << record_failure(log, e)
        end
        raise failures.first if failures.any?

        created
      end

      def ensure(model, time)
        log = RecordingStudioLogs.registry.log_for(model)
        return unless log&.partitioned?

        create_month(log, time.utc.beginning_of_month)
      end

      private

      attr_reader :connection

      def logs
        RecordingStudioLogs.registry.logs.select(&:partitioned?).select(&:loaded?)
      end

      def maintain(log)
        Names.check_table!(log.table_name)
        months = window
        created = months.filter_map { |month| create_month(log, month) }
        record_success(log, created)
        created
      end

      def window
        Window.months
      end


      def create_month(log, month)
        name = Names.partition(log.table_name, month)
        return if Catalog.exists?(log.table_name, name, connection)

        created = false
        Lock.with(connection, "partition:#{log.table_name}") do
          unless Catalog.exists?(log.table_name, name, connection)
            Catalog.create(log.table_name, name, month, month.next_month, connection)
            created = true
          end
        end
        name if created
      end

      def record_success(log, created)
        MaintenanceRun.record!(task: "partitions", subject: log.table_name, status: "succeeded",
                               details: created.join(","))
      end

      def record_failure(log, error)
        MaintenanceRun.record!(task: "partitions", subject: log.table_name, status: "failed", details: error.message)
        error
      end
    end
  end
end
