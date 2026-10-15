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

          if complete?(log, days_for(partition))
            drop(partition.name)
          else
            blocked << partition.name
          end
        end
      end

      def delete_rows(log)
        return if oldest_day(log).nil?

        covered = (oldest_day(log)...cutoff(log).to_date).to_a
        return blocked << log.table_name unless complete?(log, covered)

        drop_rows(log)
      end

      def drop(name)
        dropped << name
        return if dry_run

        Partitioning::Catalog.drop(name, connection)
      end

      def drop_rows(log)
        dropped << log.table_name
        return if dry_run

        connection.execute(delete_sql(log))
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

      def complete?(log, days)
        return true if days.empty?

        required = RecordingStudioLogs.registry.aggregations_for(log).reject(&:dormant?)
        required.all? { |definition| AggregationRun.succeeded?(definition.name, days) }
      end

      def oldest_day(log)
        quoted_table = connection.quote_table_name(log.table_name)
        quoted_time = connection.quote_column_name(log.timestamp_column)
        value = connection.select_value(<<~SQL.squish)
          SELECT MIN(#{quoted_time}) FROM #{quoted_table}
          WHERE #{quoted_time} < #{connection.quote(cutoff(log))}
        SQL
        value&.to_date
      end

      def delete_sql(log)
        quoted_table = connection.quote_table_name(log.table_name)
        quoted_time = connection.quote_column_name(log.timestamp_column)
        "DELETE FROM #{quoted_table} WHERE #{quoted_time} < #{connection.quote(cutoff(log))}"
      end
    end
  end
end
