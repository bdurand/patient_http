# frozen_string_literal: true

module PatientHttp
  # The callback arguments that a request passes to its `on_complete` and
  # `on_error` callbacks.
  #
  # The arguments are stored with string keys, so they can be serialized to
  # JSON. You can read them with string or symbol keys. The keys of nested
  # hashes, including hashes in arrays, are converted to strings.
  #
  # @example Read arguments
  #   args = CallbackArgs.new(user_id: 123, action: "fetch")
  #   args[:user_id]      # => 123
  #   args["user_id"]     # => 123
  #   args.fetch(:missing, "default")  # => "default"
  #   args.include?(:user_id)  # => true
  #   args.to_h           # => {user_id: 123, action: "fetch"}
  #
  # @example Read a nested hash
  #   args = CallbackArgs.new(metadata: {tags: ["a", "b"], level: 1})
  #   args[:metadata]     # => {"tags" => ["a", "b"], "level" => 1}
  #
  # @example Read arguments from a response
  #   response.callback_args[:user_id]
  class CallbackArgs
    # The JSON-native types that are allowed as values, in addition to `Array`
    # and `Hash`.
    ALLOWED_TYPES = [NilClass, TrueClass, FalseClass, String, Integer, Float].freeze

    class << self
      # Creates callback arguments from their serialized form. The values aren't
      # validated.
      #
      # @param hash [Hash, nil] The hash from {#as_json}.
      # @return [CallbackArgs] The callback arguments.
      def load(hash)
        new(hash || {}, validate: false)
      end

      # Validates that a value is a JSON-native type. Arrays and hashes are
      # validated recursively.
      #
      # @param value [Object] The value to validate.
      # @param path [String] The path to the value, for the error message.
      # @raise [ArgumentError] If the value isn't a JSON-native type, or if a hash
      #   key isn't a String or Symbol.
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

      # Converts all hash keys to strings, including the keys of nested hashes
      # and of hashes in arrays.
      #
      # @param value [Object] The value to convert.
      # @return [Object] The value with string keys.
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

    # Creates callback arguments.
    #
    # @param args [Hash, nil] The arguments. All keys are converted to strings.
    # @param validate [Boolean] Whether to validate that the values are JSON-native
    #   types.
    # @raise [ArgumentError] If `args` isn't `nil` and doesn't respond to `to_h`.
    # @raise [ArgumentError] If `validate` is `true` and a value isn't a
    #   JSON-native type.
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

    # Returns the value for a key.
    #
    # @param key [String, Symbol] The key.
    # @return [Object] The value.
    # @raise [KeyError] If the key doesn't exist.
    def [](key)
      string_key = key.to_s
      unless @data.include?(string_key)
        raise KeyError.new("key not found: #{key.inspect}. Available keys: #{@data.keys.join(", ")}")
      end

      @data[string_key]
    end

    # Returns the value for a key, or a default value if the key doesn't exist.
    #
    # @param key [String, Symbol] The key.
    # @param default [Object] The value to return if the key doesn't exist.
    # @return [Object] The value, or the default value.
    def fetch(key, default = nil)
      @data.fetch(key.to_s, default)
    end

    # Returns whether a key exists.
    #
    # @param key [String, Symbol] The key.
    # @return [Boolean] `true` if the key exists.
    def include?(key)
      @data.include?(key.to_s)
    end

    # Returns the arguments as a hash with symbol keys. Only the top-level keys
    # are symbols. The keys of nested hashes stay strings.
    #
    # @return [Hash] The arguments.
    def to_h
      @data.transform_keys(&:to_sym)
    end

    # Returns the arguments as a JSON-compatible hash with string keys.
    #
    # @return [Hash] The serialized arguments.
    def as_json
      @data.dup
    end

    alias_method :dump, :as_json

    # Returns whether there are no arguments.
    #
    # @return [Boolean] `true` if there are no arguments.
    def empty?
      @data.empty?
    end

    # Returns the number of arguments.
    #
    # @return [Integer] The number of top-level keys.
    def size
      @data.size
    end

    alias_method :length, :size

    # Returns the top-level keys.
    #
    # @return [Array<String>] The keys.
    def keys
      @data.keys
    end
  end
end
