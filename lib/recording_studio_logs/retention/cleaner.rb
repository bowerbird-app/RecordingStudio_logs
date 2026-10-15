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

      private

      attr_reader :dry_run, :connection, :now, :dropped, :blocked

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
        days = days_for(partition)
        release(log, partition.name, days, -> { RawRows.newest(connection, log, partition.lower, partition.upper) }) do
          Partitioning::Catalog.drop(partition.name, connection)
        end
      end

      def delete_rows(log)
        covered, waiting = fresh_days(log)
        blocked << log.table_name if waiting.any?
        return if covered.empty?

        release_rows(log, covered)
      end

      def release_rows(log, covered)
        return dropped << log.table_name if dry_run

        lock_row_delete(log, covered)
      end

      def lock_row_delete(log, covered)
        Lock.with(connection, *lock_names(log, covered)) do
          Lock.hold_writes(connection, log.table_name)
          delete_fresh_days(log, covered)
        end
      end

      def delete_fresh_days(log, covered)
        current = fresh_days(log).first & covered
        return blocked << log.table_name if current.empty?

        RawRows.delete_days(connection, log, cutoff(log), current)
        dropped << log.table_name
      end

      def fresh_days(log)
        RawRows.expired_days(connection, log, cutoff(log)).partition { |day| day_fresh?(log, day) }
      end

      def day_fresh?(log, day)
        fresh?(log, [day], RawRows.newest_for_days(connection, log, cutoff(log), [day]))
      end

      def release(log, label, days, stamp, &)
        return blocked << label unless fresh?(log, days, stamp.call)
        return dropped << label if dry_run

        drop_locked(log, label, days, stamp, &)
      end

      def drop_locked(log, label, days, stamp, &)
        Lock.with(connection, *lock_names(log, days)) do
          finish_drop(log, label, days, stamp, &)
        end
      end

      def finish_drop(log, label, days, stamp)
        Lock.hold_writes(connection, log.table_name)
        return blocked << label unless fresh?(log, days, stamp.call)

        yield
        dropped << label
      end

      def fresh?(log, days, watermark)
        AggregationRun.log_fresh?(log, days, watermark, connection: connection)
      end

      def lock_names(log, days)
        Lock.names_for(RecordingStudioLogs.registry.aggregations_for(log), days)
      end

      def expired_partition?(log, partition)
        partition.upper.present? && partition.upper <= cutoff(log)
      end

      def cutoff(log)
        now - log.retention
      end

      def days_for(partition)
        date = partition.lower.utc.to_date
        finish = partition.upper.utc.to_date
        days = []
        while date < finish
          days << date
          date += 1
        end
        days
      end
    end
  end
end
