# frozen_string_literal: true

module RecordingStudioLogs
  module Admin
    # Status labels for the read-only admin catalog.
    module Status
      module_function

      def log_status(log)
        return "Waiting" unless log.loaded?
        return "Missing month" if missing_month?(log)
        return "Cleanup waiting" if cleanup_waiting?(log)

        "OK"
      end

      def aggregation_status(definition)
        return "Waiting" if definition.dormant?
        return "Missing table" unless definition.summary_ready?
        return "Failed" if failed?(definition)

        "OK"
      end

      def last_success(definition)
        return unless runs_table?

        AggregationRun.where(aggregation_name: definition.name, status: "succeeded").order(day: :desc).pick(:day)
      end

      def range_label(partition)
        return "Unknown" if partition.lower.blank?

        "#{partition.lower.to_date} – #{partition.upper.to_date}"
      end

      def expiration_label(log, partition)
        return "Kept" if log.indefinite? || partition.upper.blank?
        return "Ready" if partition.upper <= Time.now.utc - log.retention

        "Current"
      end

      def bytes(value)
        return if value.nil?

        ActiveSupport::NumberHelper.number_to_human_size(value)
      end

      def missing_month?(log)
        return false unless log.partitioned?

        name = Partitioning::Names.partition(log.table_name, Time.now.utc.beginning_of_month)
        !Partitioning::Catalog.exists?(log.table_name, name)
      end

      def cleanup_waiting?(log)
        return false if log.indefinite? || !log.partitioned?

        Retention::Cleaner.call(dry_run: true).blocked.any? { |name| name.start_with?(log.table_name) }
      end

      def failed?(definition)
        return false unless runs_table?

        AggregationRun.where(aggregation_name: definition.name, status: "failed").exists?
      end

      def runs_table?
        AggregationRun.connection.table_exists?(AggregationRun.table_name)
      rescue ActiveRecord::ConnectionNotEstablished
        false
      end
    end
  end
end
