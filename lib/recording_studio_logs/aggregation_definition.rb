# frozen_string_literal: true

module RecordingStudioLogs
  class AggregationDefinition
    NAME_PATTERN = %r{\A[a-z0-9_]+/[a-z0-9_]+\z}
    INTERVALS = %i[daily].freeze

    attr_reader :name, :source, :summary, :filter, :group_by, :measurements, :interval, :owner

    def initialize(source:, name:, summary_model:, filter: {}, group_by: [], measurements: {}, # rubocop:disable Metrics/ParameterLists
                   interval: :daily, owner: nil)
      @source = ModelReference.new(source)
      @summary = ModelReference.new(summary_model)
      @name = name.to_s
      @filter = filter.symbolize_keys
      @group_by = Array(group_by).map(&:to_sym)
      @measurements = Measurement.parse(measurements)
      @interval = interval.to_sym
      @owner = owner.presence || @name.split("/").first
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
    end

    def summary_ready?
      !dormant? && summary_model.table_exists?
    end

    def metrics_resource
      name.tr("/", "_").to_sym
    end

    def day_for(time)
      time.utc.to_date
    end

    private

    def validate_shape!
      unless NAME_PATTERN.match?(name)
        raise InvalidRegistration,
              "aggregation names look like presskits/press_kit_views"
      end
      raise InvalidRegistration, "only daily aggregation is supported" unless INTERVALS.include?(interval)
      raise InvalidRegistration, "#{name} needs at least one measurement" if measurements.empty?
    end

    def check_contract!
      filter.each_key { |column| log.contract.allow_filter!(column) }
      group_by.each { |column| log.contract.allow_group!(column) }
      measurements.each { |measurement| check_measurement!(measurement) }
    end

    def reject_timestamp_grouping!
      return unless group_by.include?(log.timestamp_column)

      raise InvalidRegistration, "day is already the time dimension"
    end

    def check_measurement!(measurement)
      return if measurement.operation == :count

      log.contract.allow_measurement!(measurement.operation, measurement.column)
    end
  end
end
