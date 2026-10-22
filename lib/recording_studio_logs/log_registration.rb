# frozen_string_literal: true

module RecordingStudioLogs
  class LogRegistration
    INTERVALS = [nil, :monthly].freeze
    KEYS = %i[model timestamp_column partition_interval retention root_column owner aggregatable].freeze
    DEFAULTS = { partition_interval: :monthly, retention: :indefinite, aggregatable: {} }.freeze
    READERS = {
      timestamp_column: ->(values) { values.fetch(:timestamp_column).to_sym },
      partition_interval: ->(values) { normalize_interval(values[:partition_interval]) },
      declared_retention: ->(values) { Retention.normalize(values[:retention]) },
      root_column: ->(values) { values[:root_column]&.to_sym },
      owner: ->(values) { values[:owner].presence || default_owner },
      contract: ->(values) { ColumnContract.new(values[:aggregatable]) }
    }.freeze

    attr_reader :model_reference, :timestamp_column, :partition_interval, :root_column, :owner,
                :contract, :declared_retention

    def initialize(**attributes)
      attributes.assert_valid_keys(*KEYS)
      values = DEFAULTS.merge(attributes)
      @model_reference = ModelReference.new(values.fetch(:model))
      READERS.each { |name, reader| instance_variable_set(:"@#{name}", instance_exec(values, &reader)) }
      validate_timestamp!
    end

    def model_name
      model_reference.name
    end

    def model
      model_reference.resolve
    end

    def loaded?
      model_reference.loaded?
    end

    def table_name
      model.table_name
    end

    def retention
      RecordingStudioLogs.configuration.retention_override(model_name) || declared_retention
    end

    def indefinite?
      retention == :indefinite
    end

    def partitioned?
      partition_interval == :monthly
    end

    def retention_label
      return "Indefinite" if indefinite?

      distance = ActiveSupport::Duration.build(retention.to_i)
      distance.inspect
    end

    private

    def normalize_interval(value)
      interval = value&.to_sym
      return interval if INTERVALS.include?(interval)

      raise InvalidRegistration, "partition interval must be :monthly or nil"
    end

    def validate_timestamp!
      return if timestamp_column.to_s.match?(/\A[a-z_][a-z0-9_]*\z/)

      raise InvalidRegistration, "timestamp column #{timestamp_column} is not a safe name"
    end

    def default_owner
      parts = model_name.split("::")
      return "Host" if parts.size < 2

      parts[0..-2].join("::")
    end
  end
end
