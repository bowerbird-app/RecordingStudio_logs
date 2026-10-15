# frozen_string_literal: true

module RecordingStudioLogs
  class Configuration
    attr_accessor :months_ahead, :reconciliation_days
    attr_reader :hooks

    def initialize
      @months_ahead = 2
      @reconciliation_days = 3
      @retention_overrides = {}
      @hooks = RecordingStudio::Hooks.new
    end

    def retention_for(model_name, value)
      @retention_overrides[model_name.to_s] = Retention.normalize(value)
    end

    def retention_override(model_name)
      @retention_overrides[model_name.to_s]
    end

    def clear_retention_overrides!
      @retention_overrides = {}
    end

    def to_h
      {
        months_ahead: months_ahead,
        reconciliation_days: reconciliation_days,
        retention_overrides: @retention_overrides.keys,
        hooks_registered: hooks.instance_variable_get(:@registry).transform_values(&:size)
      }
    end

    def merge!(hash)
      return unless hash.respond_to?(:each)

      hash.each do |key, value|
        setter = "#{key}="
        public_send(setter, value) if respond_to?(setter)
      end
    end
  end
end
