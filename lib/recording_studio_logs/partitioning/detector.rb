# frozen_string_literal: true

module RecordingStudioLogs
  module Partitioning
    MissingPartition = Data.define(:table_name, :name, :month)

    module Detector
      module_function

      def missing(now: Time.now.utc, connection: ActiveRecord::Base.connection)
        RecordingStudioLogs.logs.flat_map { |log| missing_for(log, now: now, connection: connection) }
      end

      def missing_for(log, now: Time.now.utc, connection: ActiveRecord::Base.connection)
        return [] unless log.partitioned? && log.loaded?

        Window.months(now: now).filter_map { |month| missing_month(log, month, connection) }
      end

      def missing_month(log, month, connection)
        name = Names.partition(log.table_name, month)
        return if Catalog.exists?(log.table_name, name, connection)

        MissingPartition.new(table_name: log.table_name, name: name, month: month)
      end
    end
  end
end
