# frozen_string_literal: true

module PatientHttp
  # Helper module for class-related operations.
  #
  # This module resolves class names to class objects, which supports dynamic class
  # loading.
  module ClassHelper
    extend self

    # Resolves a class name to a class object.
    #
    # @param class_name [String] The fully qualified class name.
    # @return [Class, nil] The class object, or nil if no class name is given.
    # @raise [NameError] If the class cannot be found.
    def resolve_class_name(class_name)
      return class_name if class_name.is_a?(Class)
      return nil if class_name.nil? || class_name.empty?

      hierarchy = class_name.split("::")
      hierarchy.shift if hierarchy.first.to_s.empty? # strip leading :: for absolute names

      hierarchy.reduce(Object) { |mod, name| mod.const_get(name) }
    end
  end
end
