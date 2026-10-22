# frozen_string_literal: true

module RecordingStudioLogs
  class LogRegistration
    INTERVALS = [nil, :monthly].freeze

    attr_reader :model_reference, :timestamp_column, :partition_interval, :root_column, :owner,
                :contract, :declared_retention

    def initialize(**attributes)
      assign_identity(attributes)
      assign_contract(attributes)
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

    def assign_identity(attributes)
      @model_reference = ModelReference.new(attributes.fetch(:model))
      @timestamp_column = attributes.fetch(:timestamp_column).to_sym
      @partition_interval = normalize_interval(attributes.fetch(:partition_interval, :monthly))
      @declared_retention = Retention.normalize(attributes.fetch(:retention, :indefinite))
      @root_column = attributes[:root_column]&.to_sym
      @owner = attributes[:owner].presence || default_owner
    end

    def assign_contract(attributes)
      @contract = ColumnContract.new(attributes.fetch(:aggregatable, {}))
    end

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
