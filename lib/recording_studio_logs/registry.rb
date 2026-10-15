# frozen_string_literal: true

module RecordingStudioLogs
  class Registry
    def initialize
      @logs = {}
      @aggregations = {}
      @mutex = Mutex.new
    end

    def register_log(**attributes)
      registration = LogRegistration.new(**attributes)
      @mutex.synchronize { @logs[registration.model_name] = registration }
      validate_aggregations_for(registration)
      registration
    end

    def register_aggregation(**attributes)
      definition = AggregationDefinition.new(**attributes)
      store_aggregation(definition)
      definition.validate_against_log! if definition.log && definition.source_model
      definition
    end

    def log_for(model)
      @logs[ModelReference.new(model).name]
    end

    def aggregation(name)
      @aggregations[name.to_s] || raise(UnknownAggregation, "unknown aggregation #{name}")
    end

    def logs
      @logs.values
    end

    def aggregations
      @aggregations.values
    end

    def aggregations_for(log)
      aggregations.select { |definition| definition.source.name == log.model_name }
    end

    def finalize!
      aggregations.each do |definition|
        next if definition.source_model.nil? || definition.summary_model.nil?
        raise InvalidRegistration, "#{definition.name} source is not registered" if definition.log.nil?

        definition.validate_against_log!
      end
    end

    def reset!
      @mutex.synchronize do
        @logs = {}
        @aggregations = {}
      end
    end

    private

    def store_aggregation(definition)
      @mutex.synchronize do
        existing = @aggregations[definition.name]
        reject_other_owner!(existing, definition)
        @aggregations[definition.name] = definition
      end
    end

    def reject_other_owner!(existing, definition)
      return if existing.nil? || existing.owner == definition.owner

      raise InvalidRegistration, "#{definition.name} is already registered by #{existing.owner}"
    end

    def validate_aggregations_for(registration)
      aggregations_for(registration).each do |definition|
        next if definition.source_model.nil?

        definition.validate_against_log!
      end
    end
  end
end
