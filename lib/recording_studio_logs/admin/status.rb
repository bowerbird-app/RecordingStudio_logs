# frozen_string_literal: true

module RecordingStudioLogs
  module Admin
    # Status labels for the read-only admin catalog.
    module Status
      module_function

      def log_status(log, blocked:)
        return "Waiting" unless log.loaded?
        return "Missing month" if missing_month?(log)
        return "Cleanup waiting" if cleanup_waiting?(log, blocked)

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
        Partitioning::Detector.missing_for(log).any?
      end


      def cleanup_waiting?(log, blocked)
        return false if log.indefinite?

        blocked.any? { |name| blocked_name?(log, name) }
      end

      def blocked_name?(log, name)
        return false unless log.loaded?
        return name == log.table_name unless log.partitioned?

        name.match?(/\A#{Regexp.escape(log.table_name)}_\d{4}_\d{2}\z/)
      end

      def failed?(definition)
        return false unless runs_table?

        AggregationRun.where(aggregation_name: definition.name, status: "failed").exists?
      end

      def runs_table?
        AggregationRun.connection.table_exists?(AggregationRun.table_name)
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        false
      end
    end
  end
end
