# frozen_string_literal: true

module PatientHttp
  # A reference to a named secret that you can use as a header value or a query
  # parameter value when you build a {Request}.
  #
  # A SecretReference holds only the name of the secret, never its value. When a
  # request is serialized, for example to be enqueued in a job system, the reference
  # is serialized as a small marker, `{"$secret" => name}`, so that the sensitive
  # value is never written to the queue or to the logs. The processor resolves the
  # value at the moment the request is sent, from the secrets that are registered on
  # the {Configuration}.
  #
  # @example Referencing a secret when building a request
  #   PatientHttp.get(
  #     "https://api.example.com/data",
  #     callback: MyCallback,
  #     headers: {"Authorization" => PatientHttp.secret(:api_token)},
  #     params: {"api_key" => PatientHttp.secret(:api_key)}
  #   )
  class SecretReference
    # Key used in serialized JSON to indicate a secret reference.
    REFERENCE_KEY = "$secret"

    # @return [String] The name of the referenced secret.
    attr_reader :name

    class << self
      # Checks whether a value is a secret reference, that is, either a
      # SecretReference object or a serialized marker hash.
      #
      # @param value [Object] The value to check.
      # @return [Boolean] Whether the value is a secret reference.
      def reference?(value)
        value.is_a?(SecretReference) ||
          (value.is_a?(Hash) && value.key?(REFERENCE_KEY))
      end

      # Reconstructs a SecretReference from a serialized marker hash. Any other value,
      # including an existing SecretReference, is returned unchanged.
      #
      # @param value [Object] A serialized marker hash, or any other value.
      # @return [Object] A SecretReference for a marker hash, or the original value.
      def load(value)
        return value unless value.is_a?(Hash) && value.key?(REFERENCE_KEY)

        new(value[REFERENCE_KEY])
      end
    end

    # Initializes a new SecretReference.
    #
    # @param name [String, Symbol] The name of the secret to reference.
    # @raise [ArgumentError] If the name is empty.
    def initialize(name)
      @name = name.to_s
      raise ArgumentError.new("secret name cannot be empty") if @name.empty?
    end

    # Serializes the reference to a marker hash. Only the name is included. The value
    # is never present.
    #
    # @return [Hash] The marker hash.
    def as_json
      {REFERENCE_KEY => name}
    end

    # Checks whether another object references the same secret.
    #
    # @param other [Object] The object to compare with.
    # @return [Boolean] Whether the objects reference the same secret.
    def ==(other)
      other.is_a?(SecretReference) && other.name == name
    end
    alias_method :eql?, :==

    # Returns the hash code of the reference.
    #
    # @return [Integer] The hash code.
    def hash
      [self.class, name].hash
    end

    # Returns a description of the reference. Only the name is shown, because the
    # reference holds no value.
    #
    # @return [String] The description of the reference.
    def inspect
      "#<PatientHttp::SecretReference name=#{name.inspect}>"
    end
  end
end
