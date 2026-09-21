# frozen_string_literal: true

module PatientHttp
  # Container for the arguments that are passed to completion and error callbacks.
  #
  # CallbackArgs gives you structured access to the arguments that the original job
  # passes to the callback workers. Arguments are stored with string keys so that they
  # can be serialized as JSON, but you can access them with either strings or symbols.
  # All hash keys are converted to strings, including the keys of nested hashes and of
  # hashes inside arrays.
  #
  # @example Basic usage
  #   args = CallbackArgs.new(user_id: 123, action: "fetch")
  #   args[:user_id]      # => 123
  #   args["user_id"]     # => 123
  #   args.fetch(:missing, "default")  # => "default"
  #   args.include?(:user_id)  # => true
  #   args.to_h           # => {user_id: 123, action: "fetch"}
  #
  # @example Nested hashes
  #   args = CallbackArgs.new(metadata: {tags: ["a", "b"], level: 1})
  #   args[:metadata]     # => {"tags" => ["a", "b"], "level" => 1}
  #
  # @example From a response object
  #   response.callback_args[:user_id]
  class CallbackArgs
    # JSON-native types that are allowed as values.
    ALLOWED_TYPES = [NilClass, TrueClass, FalseClass, String, Integer, Float].freeze

    class << self
      # Reconstructs a CallbackArgs object from a hash during deserialization.
      #
      # @param hash [Hash, nil] A hash with string keys.
      # @return [CallbackArgs] The reconstructed arguments.
      def load(hash)
        new(hash || {}, validate: false)
      end

      # Validates that a value is a JSON-native type. Arrays and hashes are validated
      # recursively.
      #
      # @param value [Object] The value to validate.
      # @param path [String] The path to the value, used in error messages.
      # @return [void]
      # @raise [ArgumentError] If the value is not a JSON-native type.
      def validate_value!(value, path = "value")
        case value
        when *ALLOWED_TYPES
          # Valid primitive type
        when Array
          value.each_with_index do |element, index|
            validate_value!(element, "#{path}[#{index}]")
          end
        when Hash
          value.each do |key, val|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise ArgumentError.new("#{path} hash key must be a String or Symbol, got #{key.class.name}")
            end

            validate_value!(val, "#{path}[#{key.inspect}]")
          end
        else
          raise ArgumentError.new("#{path} must be a JSON-native type (nil, true, false, String, Integer, Float, Array, or Hash), got #{value.class.name}")
        end
      end

      # Converts all hash keys to strings, including the keys of nested hashes and of
      # hashes inside arrays.
      #
      # @param value [Object] The value to convert.
      # @return [Object] The converted value, with all hash keys as strings.
      def deep_stringify_keys(value)
        case value
        when Hash
          value.transform_keys(&:to_s).transform_values { |v| deep_stringify_keys(v) }
        when Array
          value.map { |element| deep_stringify_keys(element) }
        else
          value
        end
      end
    end

    # Initializes a new CallbackArgs object from a hash.
    #
    # @param args [Hash, nil] The arguments to store. All keys are converted to
    #   strings, including the keys of nested hashes.
    # @param validate [Boolean] Whether to validate that the values are JSON-native
    #   types.
    # @raise [ArgumentError] If args is neither nil nor an object that responds to
    #   `to_h`.
    # @raise [ArgumentError] If validate is true and a value is not a JSON-native
    #   type.
    def initialize(args = nil, validate: true)
      if args.nil?
        @data = {}
      elsif args.respond_to?(:to_h)
        hash = args.to_h
        if validate
          hash.each do |key, value|
            self.class.validate_value!(value, key.to_s)
          end
        end
        @data = self.class.deep_stringify_keys(hash)
      else
        raise ArgumentError.new("callback_args must respond to to_h, got #{args.class.name}")
      end
    end

    # Returns the argument value for a key.
    #
    # @param key [String, Symbol] The key to read.
    # @return [Object] The argument value.
    # @raise [KeyError] If the key does not exist.
    def [](key)
      string_key = key.to_s
      unless @data.include?(string_key)
        raise KeyError.new("key not found: #{key.inspect}. Available keys: #{@data.keys.join(", ")}")
      end

      @data[string_key]
    end

    # Returns the argument value for a key, or a default value.
    #
    # @param key [String, Symbol] The key to read.
    # @param default [Object] The value to return if the key does not exist.
    # @return [Object] The argument value, or the default value.
    def fetch(key, default = nil)
      @data.fetch(key.to_s, default)
    end

    # Checks whether a key exists.
    #
    # @param key [String, Symbol] The key to check.
    # @return [Boolean] Whether the key exists.
    def include?(key)
      @data.include?(key.to_s)
    end

    # Converts the arguments to a hash with symbol keys.
    #
    # Only the top-level keys become symbols. The keys of nested hashes stay strings.
    #
    # @return [Hash] A hash with symbol keys.
    def to_h
      @data.transform_keys(&:to_sym)
    end

    # Converts the arguments to a hash with string keys for serialization.
    #
    # @return [Hash] A hash with string keys.
    def as_json
      @data.dup
    end

    alias_method :dump, :as_json

    # Checks whether there are no arguments.
    #
    # @return [Boolean] Whether the arguments are empty.
    def empty?
      @data.empty?
    end

    # Returns the number of arguments.
    #
    # @return [Integer] The number of arguments.
    def size
      @data.size
    end

    alias_method :length, :size

    # Returns the argument keys.
    #
    # @return [Array<String>] The argument keys.
    def keys
      @data.keys
    end
  end
end
