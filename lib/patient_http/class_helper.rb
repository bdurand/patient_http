# frozen_string_literal: true

module PatientHttp
  # Helper module for class-related operations.
  #
  # Provides utilities for resolving class names to class objects,
  # which is useful for dynamic class loading.
  module ClassHelper
    extend self

    # Resolve a class name to the class object.
    #
    # @param class_name [String] the fully qualified class name
    # @return [Class, nil] the class object, or nil if no class name was given
    # @raise [NameError] if the class cannot be found
    def resolve_class_name(class_name)
      return class_name if class_name.is_a?(Class)
      return nil if class_name.nil? || class_name.empty?

      hierarchy = class_name.split("::")
      hierarchy.shift if hierarchy.first.to_s.empty? # strip leading :: for absolute names

      hierarchy.reduce(Object) { |mod, name| mod.const_get(name) }
    end
  end
end
