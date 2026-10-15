# frozen_string_literal: true

module RecordingStudioLogs
  # Columns a producing gem allows other gems to filter, group, or measure.
  class ColumnContract
    FILTERS = %i[eq].freeze
    MEASUREMENTS = %i[sum average minimum maximum].freeze

    def initialize(columns)
      @columns = normalize(columns || {})
    end

    def allow_filter!(column)
      entry = fetch(column)
      return if Array(entry[:filter]).map(&:to_sym).include?(:eq)

      raise InvalidRegistration, "#{column} cannot be filtered"
    end

    def allow_group!(column)
      entry = fetch(column)
      return if entry[:group]

      raise InvalidRegistration, "#{column} cannot be grouped"
    end

    def allow_measurement!(operation, column)
      return if operation.to_sym == :count

      entry = fetch(column)
      allowed = Array(entry[:measurements]).map(&:to_sym)
      return if allowed.include?(operation.to_sym)

      raise InvalidRegistration, "#{column} cannot be used for #{operation}"
    end

    private

    def fetch(column)
      @columns.fetch(column.to_sym) do
        raise InvalidRegistration, "#{column} is not aggregatable"
      end
    end

    def normalize(columns)
      columns.each_with_object({}) do |(name, options), memo|
        memo[name.to_sym] = (options || {}).symbolize_keys
      end
    end
  end
end
