# frozen_string_literal: true

module RecordingStudioLogs
  # A class or a string name. Strings stay dormant until that gem is loaded.
  class ModelReference
    def initialize(model)
      @model = model
      raise InvalidRegistration, "a model is required" if name.blank?
    end

    def name
      return @model.name if @model.is_a?(Class)

      @model.to_s
    end

    def resolve
      return @model if @model.is_a?(Class)

      name.safe_constantize
    end

    def loaded?
      !resolve.nil?
    end
  end
end
