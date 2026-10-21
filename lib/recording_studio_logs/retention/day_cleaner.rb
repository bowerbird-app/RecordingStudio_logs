# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    class DayCleaner
      def initialize(cleaner)
        @cleaner = cleaner
      end

      def delete_rows(log)
        covered, waiting = fresh_days(log)
        blocked << log.table_name if waiting.any?
        return if covered.empty?

        release_rows(log, covered)
      end

      private

      attr_reader :cleaner

      delegate :connection, :now, :dry_run, :dropped, :blocked, :cutoff, :covering_closed?,
               :lock_names_for_range, to: :cleaner

      def release_rows(log, covered)
        return dropped << log.table_name if dry_run

        lock_row_delete(log, covered)
      end

      def lock_row_delete(log, covered)
        Lock.with(connection, *lock_names_for_days(log, covered)) do
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
        start = Time.utc(day.year, day.month, day.day)
        finish = start + 1.day
        return false unless covering_closed?(log, start, finish)

        AggregationRun.range_fresh?(
          log, start, finish, RawRows.newest_for_days(connection, log, cutoff(log), [day]),
          connection: connection
        )
      end

      def lock_names_for_days(log, days)
        days.flat_map do |day|
          start = Time.utc(day.year, day.month, day.day)
          lock_names_for_range(log, start, start + 1.day)
        end
      end
    end
  end
end
