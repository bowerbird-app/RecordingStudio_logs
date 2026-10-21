# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    class CleanerContext
      attr_reader :dry_run, :connection, :now, :dropped, :blocked

      def initialize(dry_run, connection, now)
        @dry_run = dry_run
        @connection = connection
        @now = now
        @dropped = []
        @blocked = []
      end

      def cutoff(log)
        now - log.retention
      end

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
    end
  end
end
