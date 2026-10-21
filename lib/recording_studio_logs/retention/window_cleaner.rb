# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    class WindowCleaner
      def initialize(context)
        @context = context
      end

      def delete_rows(log)
        windows, waiting = fresh_windows(log)
        blocked << log.table_name if waiting
        return if windows.empty?
        return dropped << log.table_name if dry_run

        lock_window_delete(log, windows)
      end

      private

      attr_reader :context

      delegate :connection, :now, :dry_run, :dropped, :blocked, :cutoff, to: :context

      def lock_window_delete(log, windows)
        Lock.with(connection, *lock_names(log, windows)) do
          Lock.hold_writes(connection, log.table_name)
          apply_window_delete(log, windows)
        end
      end

      def apply_window_delete(log, windows)
        current, = fresh_windows(log)
        current = current.select { |window| windows.include?(window) }
        return blocked << log.table_name if current.empty?

        RawRows.delete_windows(connection, log, cutoff(log), current)
        dropped << log.table_name
      end

      def fresh_windows(log)
        definitions = RecordingStudioLogs.registry.aggregations_for(log)
        return [[], true] if definitions.empty?

        bounds = RawRows.expired_bounds(connection, log, cutoff(log))
        return [[], false] if bounds.nil?

        intersect_ready_windows(log, definitions, bounds)
      end

      def intersect_ready_windows(log, definitions, bounds)
        windows = nil
        waiting = false
        definitions.each do |definition|
          ok, rest = ready_starts(log, definition, bounds)
          waiting ||= rest.any?
          owned = ok.map { |start| definition.period.window(start) }
          windows = windows.nil? ? owned : intersect_windows(windows, owned)
        end
        [windows || [], waiting]
      end

      def ready_starts(log, definition, bounds)
        starts = definition.period.starts_overlapping(bounds[0], bounds[1] + 1.second)
        starts.partition { |start| period_ready?(log, definition, start) }
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

      def lock_names(log, windows)
        aggregations = RecordingStudioLogs.registry.aggregations_for(log)
        windows.flat_map { |lower, upper| Lock.names_for_range(aggregations, lower, upper) }
      end
    end
  end
end
