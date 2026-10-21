# frozen_string_literal: true

module RecordingStudioLogs
  class AggregationDefinition
    NAME_PATTERN = %r{\A[a-z0-9_]+/[a-z0-9_]+\z}

    attr_reader :name, :source, :summary, :filter, :group_by, :measurements, :owner, :period_options

    def initialize(source:, name:, summary_model:, filter: {}, group_by: [], measurements: {}, # rubocop:disable Metrics/ParameterLists
                   interval: nil, period: :day, every: 1, period_column: :day, count: :scheduled,
                   count_after: 0, include_current: false, owner: nil)
      @source = ModelReference.new(source)
      @summary = ModelReference.new(summary_model)
      @name = name.to_s
      @filter = filter.symbolize_keys
      @group_by = Array(group_by).map(&:to_sym)
      @measurements = Measurement.parse(measurements)
      @period_options = Aggregation::PeriodOptions.parse(
        interval:, period:, every:, period_column:, count:, count_after:, include_current:
      )
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

    def period
      period_options.period
    end

    def period_column
      period_options.period_column
    end

    def count
      period_options.count
    end

    def count_after
      period_options.count_after
    end

    def include_current
      period_options.include_current
    end

    def interval
      calendar_day? ? :daily : period.kind
    end

    def every
      period.every
    end

    def calendar_day?
      period_options.calendar_day?
    end

    def live_count?
      period_options.live_count?
    end

    def day_for(time)
      period.start_for(time).to_date
    end

    def period_start_for(time)
      period.start_for(time)
    end

    def summary_period_key(period_start)
      period_options.summary_period_key(period_start, date_column: summary_period_is_date?)
    end

    def scheduled_starts(now)
      period_options.scheduled_starts(now)
    end

    def reconciliation_starts(now)
      period_options.reconciliation_starts(now)
    end

    def count_period(period_start)
      case count
      when :sync
        Aggregation::Runner.call(self, period_start: period_start)
      when :async
        AggregatePeriodJob.enqueue(name, period_start)
      end
    end

    def install_count_hook!
      return unless live_count?

      Aggregation::CountTrigger.install(source_model)
    end

    private

    def summary_table_ready?
      return false unless summary_model.respond_to?(:table_exists?)

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

    def validate_period_column!
      period_options.validate_column!(self)
    end

    def summary_period_is_date?
      return period.kind != :hour unless summary_ready?

      summary_model.columns_hash[period_column.to_s]&.type == :date
    end
  end
end
