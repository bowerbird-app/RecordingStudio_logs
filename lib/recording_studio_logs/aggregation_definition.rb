# frozen_string_literal: true

module RecordingStudioLogs
  class AggregationDefinition # rubocop:disable Metrics/ClassLength
    NAME_PATTERN = %r{\A[a-z0-9_]+/[a-z0-9_]+\z}
    COUNTS = %i[scheduled sync async].freeze

    attr_reader :name, :source, :summary, :filter, :group_by, :measurements, :owner,
                :period, :period_column, :count, :count_after, :include_current

    def initialize(source:, name:, summary_model:, filter: {}, group_by: [], measurements: {}, # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/ParameterLists
                   interval: nil, period: :day, every: 1, period_column: :day, count: :scheduled,
                   count_after: 0, include_current: false, owner: nil)
      @source = ModelReference.new(source)
      @summary = ModelReference.new(summary_model)
      @name = name.to_s
      @filter = filter.symbolize_keys
      @group_by = Array(group_by).map(&:to_sym)
      @measurements = Measurement.parse(measurements)
      @period = Aggregation::Period.new(*coerce_period(interval, period, every))
      @period_column = period_column.to_sym
      @count = count.to_sym
      @count_after = normalize_wait(count_after)
      @include_current = include_current
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

    def interval
      calendar_day? ? :daily : period.kind
    end

    def every
      period.every
    end

    def calendar_day?
      period.kind == :day && period.every == 1 && period_column == :day
    end

    def live_count?
      count != :scheduled
    end

    def day_for(time)
      period.start_for(time).to_date
    end

    def period_start_for(time)
      period.start_for(time)
    end

    def summary_period_key(period_start)
      return period_start.to_date if summary_period_is_date?

      period_start
    end

    def scheduled_starts(now)
      now = now.to_time.utc
      current = period.start_for(now)
      closed = period.previous(current)
      starts = []
      starts << closed if now >= period.finish(closed) + count_after
      starts << current if include_current
      starts.uniq
    end

    def reconciliation_starts(now)
      current = period.start_for(now)
      count = RecordingStudioLogs.configuration.reconciliation_days
      starts = []
      cursor = period.previous(current)
      count.times do
        starts << cursor
        cursor = period.previous(cursor)
      end
      starts
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

    def coerce_period(interval, period, every)
      period = (period || :day).to_sym
      if interval
        unless interval.to_sym == :daily
          raise InvalidRegistration, "only daily interval is supported; use period: :hour"
        end
        raise InvalidRegistration, "interval: :daily cannot combine with period: #{period}" unless period == :day
      end
      [period, every]
    end

    def normalize_wait(value)
      duration = value.is_a?(Numeric) ? value.seconds : value
      unless duration.respond_to?(:to_i) && duration.to_i >= 0
        raise InvalidRegistration, "count_after must be a duration of zero or more"
      end

      duration
    end

    def validate_shape!
      unless NAME_PATTERN.match?(name)
        raise InvalidRegistration,
              "aggregation names look like presskits/press_kit_views"
      end
      raise InvalidRegistration, "#{name} needs at least one measurement" if measurements.empty?
      raise InvalidRegistration, "count must be :scheduled, :sync, or :async" unless COUNTS.include?(count)
      return if [true, false].include?(include_current)

      raise InvalidRegistration, "include_current must be true or false"
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
      return unless summary_ready?

      column = summary_model.columns_hash[period_column.to_s]
      raise InvalidRegistration, "#{name} summary needs #{period_column}" if column.nil?
      return unless period.kind == :hour && column.type == :date

      raise InvalidRegistration, "hour periods need a datetime #{period_column} column"
    end

    def summary_period_is_date?
      return period.kind != :hour unless summary_ready?

      summary_model.columns_hash[period_column.to_s]&.type == :date
    end
  end
end
