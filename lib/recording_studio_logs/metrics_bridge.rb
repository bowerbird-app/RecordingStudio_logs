# frozen_string_literal: true

module RecordingStudioLogs
  # Optional. When RecordingStudioMetrics is loaded, daily summary columns
  # become timeseries metrics. This gem does not reopen Metrics classes.
  module MetricsBridge
    PUBLISHED = %i[count sum].freeze

    module_function

    def register!
      return unless defined?(::RecordingStudioMetrics)

      RecordingStudioLogs.aggregations.each { |definition| register_one(definition) }
    end

    def register_one(definition)
      return unless publish?(definition)
      return if registered?(definition) && !reloading?

      register_resource(definition)
    end

    def publish?(definition)
      definition.calendar_day? && definition.summary_ready? && rooted?(definition) &&
        published_measurements(definition).any?
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
      defined?(Rails) && Rails.respond_to?(:application) && Rails.application &&
        Rails.application.config.respond_to?(:cache_classes) &&
        Rails.application.config.cache_classes == false
    end

    def register_resource(definition)
      rows = published_measurements(definition).map { |item| [item.name, series_options(item)] }
      RecordingStudioMetrics.register(
        definition.metrics_resource,
        model: definition.summary_model,
        scope_attribute: :root_recording_id,
        scope_value: :root_recording_id
      ) { rows.each { |name, options| timeseries(name, **options) } }
    end

    def series_options(item)
      {
        field: :day, measurement: :sum, value_field: item.name, title: item.name.to_s.humanize,
        unit: item.operation == :count ? "count" : item.operation.to_s,
        description: "Fresh UTC-day rollup of #{item.name}. Empty days are zero.",
        semantics: "utc_day_rollup", bucket_timezone: "UTC", fill_gaps: true
      }
    end
  end
end
