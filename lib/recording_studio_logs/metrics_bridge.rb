# frozen_string_literal: true

module RecordingStudioLogs
  # Optional. When RecordingStudioMetrics is loaded, daily summary columns
  # become timeseries metrics. This gem does not depend on metrics.
  module MetricsBridge
    PUBLISHED = %i[count sum].freeze

    module_function

    def register!
      return unless defined?(::RecordingStudioMetrics)

      install_summary_series!
      RecordingStudioLogs.aggregations.each { |definition| register_one(definition) }
    end

    def install_summary_series!
      return unless defined?(RecordingStudioMetrics::Calculators::Timeseries)

      calculator = RecordingStudioMetrics::Calculators::Timeseries
      return if calculator.ancestors.include?(SummarySeries)

      calculator.prepend(SummarySeries)
    end

    def register_one(definition)
      return unless publish?(definition)
      return if registered?(definition) && !reloading?

      register_resource(definition)
    end

    def publish?(definition)
      definition.summary_ready? && rooted?(definition) && published_measurements(definition).any?
    end

    def rooted?(definition)
      definition.rooted_group?
    end

    def published_measurements(definition)
      definition.measurements.select { |measurement| PUBLISHED.include?(measurement.operation) }
    end

    def registered?(definition)
      RecordingStudioMetrics.for_resource(definition.metrics_resource).any?
    end

    def reloading?
      Rails.application.config.cache_classes == false
    rescue StandardError
      false
    end

    def register_resource(definition)
      rows = published_measurements(definition)
      options = series_options
      RecordingStudioMetrics.register(
        definition.metrics_resource,
        model: definition.summary_model,
        scope_attribute: definition.log.root_column
      ) { rows.each { |item| timeseries(item.name, **options.call(item)) } }
    end

    def series_options
      lambda { |item|
        { field: :day, measurement: :sum, value_field: item.name, title: item.name.to_s.humanize }
      }
    end

    module SummarySeries
      def fill_missing?(_measurement)
        summary_day? ? false : super
      end

      def truncation_sql(window)
        summary_day? ? day_sql(window) : super
      end

      def summary_day?
        model = relation.klass
        definition.field.to_s == "day" && RecordingStudioLogs.aggregations.any? do |item|
          item.summary_model == model
        end
      rescue StandardError
        false
      end

      def day_sql(window)
        connection = relation.klass.connection
        table = relation.klass.quoted_table_name
        column = connection.quote_column_name(definition.field)
        interval = connection.quote(window.pg_interval)
        "date_trunc(#{interval}, #{table}.#{column}::timestamp)::date"
      end
    end
  end
end
