# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    CleanupReport = Data.define(:dropped, :blocked, :dry_run)

    class Cleaner # rubocop:disable Metrics/ClassLength
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
        stamp = -> { RawRows.newest(connection, log, partition.lower, partition.upper) }
        release(log, partition.name, partition.lower, partition.upper, stamp) do
          Partitioning::Catalog.drop(partition.name, connection)
        end
      end

      def delete_rows(log)
        return delete_day_rows(log) if calendar_only?(log)

        delete_window_rows(log)
      end

      def delete_day_rows(log)
        covered, waiting = fresh_days(log)
        blocked << log.table_name if waiting.any?
        return if covered.empty?

        release_rows(log, covered)
      end

      def delete_window_rows(log)
        windows, waiting = fresh_windows(log)
        blocked << log.table_name if waiting
        return if windows.empty?
        return dropped << log.table_name if dry_run

        lock_window_delete(log, windows)
      end

      def lock_window_delete(log, windows) # rubocop:disable Metrics/AbcSize
        locks = windows.flat_map { |lower, upper| lock_names_for_range(log, lower, upper) }
        Lock.with(connection, *locks) do
          Lock.hold_writes(connection, log.table_name)
          current, = fresh_windows(log)
          current = current.select { |window| windows.include?(window) }
          return blocked << log.table_name if current.empty?

          RawRows.delete_windows(connection, log, cutoff(log), current)
          dropped << log.table_name
        end
      end

      def calendar_only?(log)
        definitions = RecordingStudioLogs.registry.aggregations_for(log)
        definitions.any? && definitions.all?(&:calendar_day?)
      end

      def fresh_windows(log) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        definitions = RecordingStudioLogs.registry.aggregations_for(log)
        return [[], true] if definitions.empty?

        bounds = RawRows.expired_bounds(connection, log, cutoff(log))
        return [[], false] if bounds.nil?

        windows = nil
        waiting = false
        definitions.each do |definition|
          starts = definition.period.starts_overlapping(bounds[0], bounds[1] + 1.second)
          ok, rest = starts.partition { |start| period_ready?(log, definition, start) }
          waiting ||= rest.any?
          owned = ok.map { |start| definition.period.window(start) }
          windows = windows.nil? ? owned : intersect_windows(windows, owned)
        end
        [windows || [], waiting]
      end

      def period_ready?(log, definition, start)
        return false unless definition.period.closed?(start, now)

        lower, upper = definition.period.window(start)
        watermark = RawRows.newest_before(connection, log, cutoff(log), lower, upper)
        AggregationRun.fresh?(definition.name, [start], watermark, connection: connection)
      end

      def intersect_windows(left, right)
        left.each_with_object([]) do |(left_start, left_end), result|
          right.each do |right_start, right_end|
            lower = [left_start, right_start].max
            upper = [left_end, right_end].min
            result << [lower, upper] if lower < upper
          end
        end
      end

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

      def covering_closed?(log, lower, upper)
        definitions = RecordingStudioLogs.registry.aggregations_for(log)
        return false if definitions.empty?

        definitions.all? do |definition|
          starts = definition.period.starts_overlapping(lower, upper)
          starts.any? && starts.all? { |start| definition.period.closed?(start, now) }
        end
      end

      def lock_names_for_days(log, days)
        days.flat_map do |day|
          start = Time.utc(day.year, day.month, day.day)
          lock_names_for_range(log, start, start + 1.day)
        end
      end

      def lock_names_for_range(log, lower, upper)
        Lock.names_for_range(RecordingStudioLogs.registry.aggregations_for(log), lower, upper)
      end

      def expired_partition?(log, partition)
        partition.upper.present? && partition.upper <= cutoff(log)
      end

      def cutoff(log)
        now - log.retention
      end
    end
  end
end
