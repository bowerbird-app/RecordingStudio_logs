# frozen_string_literal: true

module RecordingStudioLogs
  module Retention
    OwnerDeletionReport = Data.define(:root_recording_id, :tables, :unscoped_aggregations, :dry_run)

    class OwnerDeletion
      def self.call(root_recording_id:, dry_run: false, connection: ActiveRecord::Base.connection)
        new(root_recording_id, dry_run, connection).call
      end

      def initialize(root_recording_id, dry_run, connection)
        @root_recording_id = root_recording_id
        @dry_run = dry_run
        @connection = connection
      end

      def call
        return report(counted) if dry_run
        return report([]) if dormant_consumer?

        hold
      end

      def hold
        days = affected_days
        Lock.with(connection, *Lock.names_for(loaded_consumers, days)) do
          current = affected_days
          Lock.acquire(connection, *Lock.names_for(loaded_consumers, current))
          report(delete_and_rebuild(current))
        end
      end

      private

      attr_reader :root_recording_id, :dry_run, :connection

      def report(tables)
        OwnerDeletionReport.new(
          root_recording_id: root_recording_id, tables: tables,
          unscoped_aggregations: unscoped.map(&:name), dry_run: dry_run
        )
      end

      def dormant_consumer?
        consumers.any?(&:dormant?)
      end

      def counted
        rooted_logs.map { |log| row_count(log.table_name, log.root_column) } + summary_counts
      end

      def summary_counts
        scoped.filter_map { |definition| summary_count(definition) }
      end

      def summary_count(definition)
        return unless summary_table?(definition)

        row_count(definition.summary_model.table_name, definition.log.root_column)
      end

      def delete_and_rebuild(days)
        removed = remove_matching
        rebuild(days)
        removed
      end

      def remove_matching
        rooted_logs.map { |log| removed_count(log.table_name, log.root_column) } + removed_summaries
      end

      def removed_summaries
        scoped.filter_map { |definition| remove_summary(definition) }
      end

      def remove_summary(definition)
        return unless summary_table?(definition)

        removed_count(definition.summary_model.table_name, definition.log.root_column)
      end

      def rebuild(days)
        unscoped.each do |definition|
          days.each { |day| Aggregation::Runner.call(definition, day: day, connection: connection) }
        end
      end

      def row_count(table_name, column)
        { table: table_name, rows: count_rows(table_name, column) }
      end

      def removed_count(table_name, column)
        { table: table_name, rows: remove_rows(table_name, column) }
      end

      def summary_table?(definition)
        definition.summary_model&.table_exists?
      end

      def rooted_logs
        RecordingStudioLogs.registry.logs.select { |log| log.loaded? && log.root_column }
      end

      def consumers
        rooted_logs.flat_map { |log| RecordingStudioLogs.registry.aggregations_for(log) }
      end

      def scoped
        loaded_consumers.select(&:rooted_group?)
      end

      def unscoped
        loaded_consumers.reject(&:rooted_group?)
      end

      def loaded_consumers
        consumers.reject(&:dormant?)
      end

      def affected_days
        rooted_logs.flat_map { |log| days_in(log) }.uniq
      end

      def days_in(log)
        RawRows.days_for(connection, log.table_name, log.timestamp_column, log.root_column, root_recording_id)
      end

      def count_rows(table_name, column)
        RawRows.count(connection, table_name, column, root_recording_id)
      end

      def remove_rows(table_name, column)
        RawRows.delete(connection, table_name, column, root_recording_id)
      end
    end
  end
end
