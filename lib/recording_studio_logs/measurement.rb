# frozen_string_literal: true

module RecordingStudioLogs
  class Measurement
    OPERATIONS = %i[count sum average minimum maximum].freeze
    NAME_PATTERN = /\A[a-z_][a-z0-9_]*\z/

    attr_reader :name, :operation, :column

    def initialize(name, operation, column = nil)
      @name = name.to_sym
      @operation = operation.to_sym
      @column = column&.to_sym
      validate!
    end

    def self.parse(measurements)
      Array(measurements).map { |name, spec| build(name, spec) }
    end

    def sql(connection)
      case operation
      when :count then "COUNT(*)"
      when :sum then "COALESCE(SUM(#{quote(connection)}), 0)"
      when :average then "AVG(#{quote(connection)})"
      when :minimum then "MIN(#{quote(connection)})"
      when :maximum then "MAX(#{quote(connection)})"
      end
    end

    def self.build(name, spec)
      operation, column = parts(spec)
      new(name, operation, column)
    end
    private_class_method :build

    def self.parts(spec)
      return [:count, nil] if [:count, "count"].include?(spec)
      return pair(spec) if spec.is_a?(Hash) && spec.size == 1

      raise InvalidRegistration, "measurements need :count or { operation: :column }"
    end
    private_class_method :parts

    def self.pair(spec)
      operation, column = spec.first
      [operation.to_sym, column.to_sym]
    end
    private_class_method :pair

    private

    def validate!
      raise InvalidRegistration, "bad measurement name #{name}" unless NAME_PATTERN.match?(name.to_s)
      raise InvalidRegistration, "unknown measurement #{operation}" unless OPERATIONS.include?(operation)
      raise InvalidRegistration, "#{operation} needs a column" if operation != :count && column.nil?
    end

    def quote(connection)
      connection.quote_column_name(column)
    end
  end
end
