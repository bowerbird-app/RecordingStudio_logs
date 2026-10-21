# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    CleanupReport = Data.define(:dropped, :blocked, :dry_run)

    class Cleaner
      def self.call(dry_run: false, connection: ActiveRecord::Base.connection, now: Time.now.utc)
        new(dry_run, connection, now).call
      end

      def initialize(dry_run, connection, now)
        @dry_run = dry_run
        @connection = connection
        @now = now
        @dropped = []
        @blocked = []
      end

      def call
        RecordingStudioLogs.registry.logs.select(&:loaded?).each { |log| clean(log) }
        CleanupReport.new(dropped: dropped, blocked: blocked, dry_run: dry_run)
      end

      attr_reader :dry_run, :connection, :now, :dropped, :blocked

      def covering_closed?(log, lower, upper)
        definitions = RecordingStudioLogs.registry.aggregations_for(log)
        return false if definitions.empty?

        definitions.all? do |definition|
          starts = definition.period.starts_overlapping(lower, upper)
          starts.any? && starts.all? { |start| definition.period.closed?(start, now) }
        end
      end

      def lock_names_for_range(log, lower, upper)
        Lock.names_for_range(RecordingStudioLogs.registry.aggregations_for(log), lower, upper)
      end

      def cutoff(log)
        now - log.retention
      end

      private

      def clean(log)
        return if log.indefinite?

        log.partitioned? ? drop_partitions(log) : delete_rows(log)
      end

      def drop_partitions(log)
        Partitioning::Catalog.list(log.table_name, connection).each do |partition|
          next unless expired_partition?(log, partition)

          release_partition(log, partition)
        end
      end

      def release_partition(log, partition)
        stamp = -> { RawRows.newest(connection, log, partition.lower, partition.upper) }
        release(log, partition.name, partition.lower, partition.upper, stamp) do
          Partitioning::Catalog.drop(partition.name, connection)
        end
      end

      def delete_rows(log)
        return DayCleaner.new(self).delete_rows(log) if calendar_only?(log)

        WindowCleaner.new(self).delete_rows(log)
      end

      def calendar_only?(log)
        definitions = RecordingStudioLogs.registry.aggregations_for(log)
        definitions.any? && definitions.all?(&:calendar_day?)
      end

      def release(log, label, lower, upper, stamp, &)
        return blocked << label unless range_ready?(log, lower, upper, stamp.call)
        return dropped << label if dry_run

        drop_locked(log, label, lower, upper, stamp, &)
      end

      def drop_locked(log, label, lower, upper, stamp, &)
        Lock.with(connection, *lock_names_for_range(log, lower, upper)) do
          finish_drop(log, label, lower, upper, stamp, &)
        end
      end

      def finish_drop(log, label, lower, upper, stamp)
        Lock.hold_writes(connection, log.table_name)
        return blocked << label unless range_ready?(log, lower, upper, stamp.call)

        yield
        dropped << label
      end

      def range_ready?(log, lower, upper, watermark)
        covering_closed?(log, lower, upper) &&
          AggregationRun.range_fresh?(log, lower, upper, watermark, connection: connection)
      end

      def expired_partition?(log, partition)
        partition.upper.present? && partition.upper <= cutoff(log)
      end
    end
  end
end
