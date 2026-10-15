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
        OwnerDeletionReport.new(
          root_recording_id: root_recording_id,
          tables: deletions,
          unscoped_aggregations: unscoped.map(&:name),
          dry_run: dry_run
        )
      end

      private

      attr_reader :root_recording_id, :dry_run, :connection

      def deletions
        log_deletions + summary_deletions
      end

      def log_deletions
        rooted_logs.map { |log| delete_rows(log.table_name, log.root_column) }
      end

      def summary_deletions
        scoped_aggregations.filter_map { |definition| delete_summary(definition) }
      end

      def rooted_logs
        RecordingStudioLogs.registry.logs.select { |log| log.loaded? && log.root_column }
      end

      def scoped_aggregations
        aggregations.select { |definition| definition.group_by.include?(definition.log.root_column) }
      end

      def unscoped
        aggregations.reject { |definition| definition.group_by.include?(definition.log.root_column) }
      end

      def aggregations
        rooted_logs.flat_map { |log| RecordingStudioLogs.registry.aggregations_for(log) }.reject(&:dormant?)
      end

      def delete_summary(definition)
        return unless definition.summary_model&.table_exists?

        delete_rows(definition.summary_model.table_name, definition.log.root_column)
      end

      def delete_rows(table_name, column)
        { table: table_name, rows: dry_run ? count(table_name, column) : remove(table_name, column) }
      end

      def count(table_name, column)
        connection.select_value("SELECT COUNT(*) FROM #{quoted(table_name)} WHERE #{match(column)}").to_i
      end

      def remove(table_name, column)
        connection.exec_delete("DELETE FROM #{quoted(table_name)} WHERE #{match(column)}", "Owner deletion")
      end

      def match(column)
        "#{connection.quote_column_name(column)} = #{connection.quote(root_recording_id)}"
      end

      def quoted(table_name)
        connection.quote_table_name(table_name)
      end
    end
  end
end
