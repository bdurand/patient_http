# frozen_string_literal: true

module PatientHttp
  # Helper methods for resolving class names to class objects when loading
  # classes dynamically.
  module ClassHelper
    extend self

    # Resolves a class name to its class object.
    #
    # @param class_name [String] The fully qualified class name.
    # @return [Class, nil] The class object, or `nil` if `class_name` is empty.
    # @raise [NameError] If the class can't be found.
    def resolve_class_name(class_name)
      return class_name if class_name.is_a?(Class)
      return nil if class_name.nil? || class_name.empty?

      hierarchy = class_name.split("::")
      hierarchy.shift if hierarchy.first.to_s.empty? # strip leading :: for absolute names

      hierarchy.reduce(Object) { |mod, name| mod.const_get(name) }
    end
  end
end
