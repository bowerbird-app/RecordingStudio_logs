# frozen_string_literal: true

module RecordingStudioLogs
  class AggregationDefinition
    include Aggregation::DefinitionPeriod

    NAME_PATTERN = %r{\A[a-z0-9_]+/[a-z0-9_]+\z}

    attr_reader :name, :source, :summary, :filter, :group_by, :measurements, :owner, :period_options

    delegate :period, :period_column, :count, :count_after, :include_current,
             :calendar_day?, :live_count?, :scheduled_starts, :reconciliation_starts,
             to: :period_options

    def initialize(source:, name:, summary_model:, filter: {}, group_by: [], measurements: {}, # rubocop:disable Metrics/ParameterLists
                   interval: nil, period: :day, every: 1, period_column: :day, count: :scheduled,
                   count_after: 0, include_current: false, owner: nil)
      @source = ModelReference.new(source)
      @summary = ModelReference.new(summary_model)
      assign_shape(name, filter, group_by, measurements, owner)
      @period_options = Aggregation::PeriodOptions.parse(
        interval:, period:, every:, period_column:, count:, count_after:, include_current:
      )
      validate_shape!
    end

    def source_model
      source.resolve
    end

    def summary_model
      summary.resolve
    end

    def log
      RecordingStudioLogs.registry.log_for(source.name)
    end

    def dormant?
      source_model.nil? || summary_model.nil? || log.nil?
    end

    def validate_against_log!
      raise InvalidRegistration, "#{name} has no registered source" if log.nil?

      reject_timestamp_grouping!
      check_contract!
      validate_period_column!
    end

    def rooted_group?
      root = log&.root_column
      root.present? && group_by.include?(root)
    end

    def summary_ready?
      !dormant? && summary_table_ready?
    end

    def metrics_resource
      name.tr("/", "_").to_sym
    end

    private

    def assign_shape(name, filter, group_by, measurements, owner)
      @name = name.to_s
      @filter = filter.symbolize_keys
      @group_by = Array(group_by).map(&:to_sym)
      @measurements = Measurement.parse(measurements)
      @owner = owner.presence || @name.split("/").first
    end

    def summary_table_ready?
      summary_model.table_exists?
    rescue ActiveRecord::NoDatabaseError, ActiveRecord::ConnectionNotEstablished
      false
    end

    def validate_shape!
      unless NAME_PATTERN.match?(name)
        raise InvalidRegistration,
              "aggregation names look like presskits/press_kit_views"
      end
      raise InvalidRegistration, "#{name} needs at least one measurement" if measurements.empty?
    end

    def check_contract!
      filter.each_key { |column| log.contract.allow_filter!(column) }
      group_by.each { |column| log.contract.allow_group!(column) }
      measurements.each { |measurement| check_measurement!(measurement) }
    end

    def reject_timestamp_grouping!
      return unless group_by.include?(log.timestamp_column)

      raise InvalidRegistration, "the period is already the time dimension"
    end

    def check_measurement!(measurement)
      return if measurement.operation == :count

      log.contract.allow_measurement!(measurement.operation, measurement.column)
    end
  end
end
