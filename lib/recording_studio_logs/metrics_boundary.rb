# frozen_string_literal: true

module RecordingStudioLogs
  module MetricsBoundary
    module_function

    def install!
      return if defined?(@installed) && @installed

      RecordingStudioMetrics::Context.prepend(ZoneError)
      RecordingStudioMetrics::TimeWindow.prepend(TimeValueError)
      RecordingStudioMetrics::Executor.singleton_class.prepend(GroupByError)
      RecordingStudioMetrics::Authorization.singleton_class.prepend(SummaryScope)
      @installed = true
    end

    module ZoneError
      def validate!
        super
      rescue ArgumentError
        raise RecordingStudioMetrics::Errors::InvalidDateRange, "invalid timezone"
      end
    end

    module TimeValueError
      def coerce(value)
        super
      rescue TypeError
        raise RecordingStudioMetrics::Errors::InvalidDateRange, "invalid time value"
      end
    end

    module GroupByError
      def call(identifier, context:, **params)
        if params.key?(:group_by) && MetricsBoundary.owns?(identifier)
          raise RecordingStudioMetrics::Errors::InvalidFilter, "group_by is not supported"
        end

        super
      end
    end

    def owns?(identifier)
      resource = identifier.to_s.split(".", 2).first
      return false if resource.blank?

      aggregations = RecordingStudioLogs.aggregations
      return true if aggregations.any? { |item| item.metrics_resource.to_s == resource }

      definition = RecordingStudioMetrics.find(identifier)
      return false unless definition

      aggregations.any? { |item| item.summary_model == definition.model }
    end

    module SummaryScope
      def apply_root_or_recording_scope(relation, definition, context)
        column = root_column_for(definition)
        root_id = root_id_for(context) if column
        return relation.where(column => root_id) if column && root_id

        super
      end

      def root_column_for(definition)
        summary = RecordingStudioLogs.aggregations.find { |item| item.summary_model == definition.model }
        summary&.log&.root_column
      end

      def root_id_for(context)
        context.root_recording&.id || context.workspace_id
      end
    end
  end
end
