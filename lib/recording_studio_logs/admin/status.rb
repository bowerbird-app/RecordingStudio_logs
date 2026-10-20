# frozen_string_literal: true

module RecordingStudioLogs
  module Admin
    # Status labels for the read-only admin catalog.
    module Status
      NEEDS_ATTENTION = "Needs attention"
      OK = "OK"
      WAITING = "Waiting"
      MISSING_MONTH = "Missing month"
      CLEANUP_WAITING = "Cleanup waiting"
      MISSING_TABLE = "Missing table"
      FAILED = "Failed"

      LOG_FILTERS = [NEEDS_ATTENTION, OK, WAITING, MISSING_MONTH, CLEANUP_WAITING].freeze
      SUMMARY_FILTERS = [NEEDS_ATTENTION, OK, WAITING, MISSING_TABLE, FAILED].freeze

      module_function

      def log_status(log, blocked:)
        return WAITING unless log.loaded?
        return MISSING_MONTH if missing_month?(log)
        return CLEANUP_WAITING if cleanup_waiting?(log, blocked)

        OK
      end

      def aggregation_status(definition)
        return WAITING if definition.dormant?
        return MISSING_TABLE unless definition.summary_ready?
        return FAILED if failed?(definition)

        OK
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

      def badge_options(value)
        { text: value.to_s, size: :sm, style: badge_style(value) }
      end

      def badge_style(value)
        case value.to_s
        when OK, "succeeded" then :success
        when FAILED, MISSING_TABLE, "failed" then :danger
        when MISSING_MONTH, CLEANUP_WAITING then :warning
        else :default
        end
      end

      def matching(rows, value)
        return rows if value.blank?
        return rows.select { |row| row.status != OK } if value == NEEDS_ATTENTION

        rows.select { |row| row.status == value }
      end

      def needs_attention_path(context, screen_key)
        "#{context.admin_screen_path(screen_key)}?#{ { status: NEEDS_ATTENTION }.to_query }"
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
