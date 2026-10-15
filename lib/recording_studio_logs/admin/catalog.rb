# frozen_string_literal: true

module RecordingStudioLogs
  module Admin
    LogRow = Data.define(:id, :key, :name, :owner, :table_name, :retention, :partitioning, :aggregations, :rows,
                         :storage, :status)
    PartitionRow = Data.define(:id, :name, :range, :rows, :storage, :expiration)
    AggregationRow = Data.define(:id, :key, :name, :source, :owner, :filters, :grouping, :measurements, :interval,
                                 :last_success, :status)
    RunRow = Data.define(:id, :day, :status, :finished_at, :error_message)

    module Catalog
      module_function

      def logs
        waiting = cleanup_blocked
        RecordingStudioLogs.logs.map { |log| log_row(log, waiting) }
      end

      def cleanup_blocked
        Retention::Cleaner.call(dry_run: true).blocked
      rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
        []
      end

      def attention_count
        logs.count { |row| row.status != "OK" }
      end

      def stuck_count
        aggregations.count { |row| row.status != "OK" }
      end

      def partitions_for(key)
        log = log_for(key)
        return [] if log.nil? || !log.partitioned? || !log.loaded?

        Partitioning::Catalog.list(log.table_name).map { |partition| partition_row(log, partition) }
      end

      def aggregations
        RecordingStudioLogs.aggregations.map { |definition| aggregation_row(definition) }
      end

      def runs_for(key)
        return [] unless Status.runs_table?

        AggregationRun.where(aggregation_name: key).order(day: :desc).limit(31).map { |run| run_row(run) }
      end

      def log_for(key)
        RecordingStudioLogs.logs.find { |log| log.model_name == key }
      end

      def log_row(log, blocked)
        stats = storage_for(log)
        LogRow.new(
          id: log.model_name, key: log.model_name, name: log.model_name, owner: log.owner,
          table_name: loaded_table(log), retention: log.retention_label, partitioning: partition_label(log),
          aggregations: RecordingStudioLogs.registry.aggregations_for(log).size,
          rows: stats[:rows], storage: stats[:storage], status: Status.log_status(log, blocked: blocked)
        )
      end

      def partition_row(log, partition)
        PartitionRow.new(
          id: partition.name, name: partition.name, range: Status.range_label(partition),
          rows: partition.estimated_rows, storage: Status.bytes(partition.bytes),
          expiration: Status.expiration_label(log, partition)
        )
      end

      def aggregation_row(definition)
        AggregationRow.new(**aggregation_identity(definition), **aggregation_activity(definition))
      end

      def aggregation_identity(definition)
        {
          id: definition.name, key: definition.name, name: definition.name, source: definition.source.name,
          owner: definition.owner, filters: definition.filter.inspect
        }
      end

      def aggregation_activity(definition)
        {
          grouping: definition.group_by.join(", "), measurements: definition.measurements.map(&:name).join(", "),
          interval: definition.interval.to_s, last_success: Status.last_success(definition),
          status: Status.aggregation_status(definition)
        }
      end

      def run_row(run)
        RunRow.new(id: run.id, day: run.day, status: run.status, finished_at: run.finished_at,
                   error_message: run.error_message)
      end

      def loaded_table(log)
        log.loaded? ? log.table_name : "waiting"
      end

      def partition_label(log)
        log.partitioned? ? "Monthly" : "None"
      end

      def storage_for(log)
        return { rows: nil, storage: nil } unless log.loaded? && log.partitioned?

        parts = Partitioning::Catalog.list(log.table_name)
        { rows: parts.sum { |part| part.estimated_rows.to_i }, storage: Status.bytes(parts.sum(&:bytes)) }
      end
    end
  end
end
