# frozen_string_literal: true

module PatientHttp
  # Container for callback arguments that are passed to completion and error callbacks.
  #
  # CallbackArgs provides a structured way to access arguments passed from the original
  # job to the callback workers. Arguments are stored with string keys internally
  # (for JSON serialization compatibility) but can be accessed using either strings
  # or symbols. All hash keys, including nested hashes and hashes within arrays, are
  # deeply converted to strings.
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
    # JSON-native types that are allowed as values
    ALLOWED_TYPES = [NilClass, TrueClass, FalseClass, String, Integer, Float].freeze

    class << self
      # Reconstruct a CallbackArgs from a hash (used during deserialization).
      #
      # @param hash [Hash, nil] hash with string keys
      # @return [CallbackArgs] reconstructed CallbackArgs
      def load(hash)
        new(hash || {}, validate: false)
      end

      # Validate that a value is a JSON-native type (recursively for arrays and hashes).
      #
      # @param value [Object] the value to validate
      # @param path [String] the path to the value (for error messages)
      # @raise [ArgumentError] if the value is not a JSON-native type
      # @return [void]
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

      # Deep convert all hash keys to strings, including nested hashes and hashes in arrays.
      #
      # @param value [Object] the value to convert
      # @return [Object] the converted value with all hash keys as strings
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

    # Initialize a CallbackArgs with a hash.
    #
    # @param args [Hash, nil] arguments to store (keys will be deeply converted to strings)
    # @param validate [Boolean] whether to validate values are JSON-native types
    # @raise [ArgumentError] if args is not nil and doesn't respond to to_h
    # @raise [ArgumentError] if any value is not a JSON-native type (when validate is true)
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

    # Access an argument by key.
    #
    # @param key [String, Symbol] the key to access
    # @return [Object] the value
    # @raise [KeyError] if the key does not exist
    def [](key)
      string_key = key.to_s
      unless @data.include?(string_key)
        raise KeyError.new("key not found: #{key.inspect}. Available keys: #{@data.keys.join(", ")}")
      end

      @data[string_key]
    end

    # Access an argument by key with an optional default.
    #
    # @param key [String, Symbol] the key to access
    # @param default [Object] the default value to return if key doesn't exist
    # @return [Object] the value or default
    def fetch(key, default = nil)
      @data.fetch(key.to_s, default)
    end

    # Check if a key exists.
    #
    # @param key [String, Symbol] the key to check
    # @return [Boolean] true if the key exists
    def include?(key)
      @data.include?(key.to_s)
    end

    # Convert to a hash with symbol keys.
    #
    # @return [Hash] hash with symbol keys
    def to_h
      @data.transform_keys(&:to_sym)
    end

    # Convert to hash with string keys for serialization.
    #
    # @return [Hash] hash with string keys
    def as_json
      @data.dup
    end

    alias_method :dump, :as_json

    # Check if there are no arguments.
    #
    # @return [Boolean] true if empty
    def empty?
      @data.empty?
    end

    # Return the number of arguments.
    #
    # @return [Integer] the count
    def size
      @data.size
    end

    alias_method :length, :size

    # Return the keys.
    #
    # @return [Array<String>] the keys
    def keys
      @data.keys
    end
  end
end
