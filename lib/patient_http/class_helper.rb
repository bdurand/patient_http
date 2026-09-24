# frozen_string_literal: true

module PatientHttp
  # Resolves class names to classes.
  #
  # @api private
  module ClassHelper
    extend self

    # Returns the class for a class name.
    #
    # @param class_name [String] The fully qualified class name.
    # @return [Class, nil] The class object or nil if no class_name given.
    # @raise [NameError] If class cannot be found.
    def resolve_class_name(class_name)
      return class_name if class_name.is_a?(Class)
      return nil if class_name.nil? || class_name.empty?

      hierarchy = class_name.split("::")
      hierarchy.shift if hierarchy.first.to_s.empty? # strip leading :: for absolute names

      hierarchy.reduce(Object) { |mod, name| mod.const_get(name) }
    end
  end
end
