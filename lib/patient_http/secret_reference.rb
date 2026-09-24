# frozen_string_literal: true

module PatientHttp
  # A reference to a named secret. Use it as a header or query parameter value
  # when you build a {Request}.
  #
  # A secret reference holds only the name of the secret, never its value. When a
  # request is serialized, for example to enqueue it in a job system, the
  # reference is serialized as a small marker, `{"$secret" => name}`. The sensitive
  # value is never written to the queue or logs. The processor resolves the value
  # when it sends the request, using the secrets registered on the {Configuration}.
  #
  # @example Referencing a secret when building a request
  #   PatientHttp.get(
  #     "https://api.example.com/data",
  #     callback: MyCallback,
  #     headers: {"Authorization" => PatientHttp.secret(:api_token)},
  #     params: {"api_key" => PatientHttp.secret(:api_key)}
  #   )
  class SecretReference
    # The key that marks a secret reference in serialized JSON.
    REFERENCE_KEY = "$secret"

    # @return [String] The name of the referenced secret.
    attr_reader :name

    class << self
      # Returns `true` if a value is a secret reference. A secret reference is a
      # {SecretReference} object or a serialized marker hash.
      #
      # @param value [Object] The value to check.
      # @return [Boolean] `true` if the value is a secret reference.
      def reference?(value)
        value.is_a?(SecretReference) ||
          (value.is_a?(Hash) && value.key?(REFERENCE_KEY))
      end

      # Reconstructs a secret reference from a serialized marker hash. Any other
      # value, including an existing {SecretReference}, is returned unchanged.
      #
      # @param value [Object] A serialized marker hash or any other value.
      # @return [Object] A {SecretReference} for a marker hash, or the original value.
      def load(value)
        return value unless value.is_a?(Hash) && value.key?(REFERENCE_KEY)

        new(value[REFERENCE_KEY])
      end
    end

    # Creates a secret reference.
    #
    # @param name [String, Symbol] The name of the secret to reference.
    # @raise [ArgumentError] If the name is empty.
    def initialize(name)
      @name = name.to_s
      raise ArgumentError.new("secret name cannot be empty") if @name.empty?
    end

    # Serializes the reference to a marker hash. The hash includes only the name,
    # never the value.
    #
    # @return [Hash] The marker hash.
    def as_json
      {REFERENCE_KEY => name}
    end

    # Returns `true` if another object is a {SecretReference} with the same name.
    #
    # @param other [Object] The object to compare.
    # @return [Boolean] `true` if the references are equal.
    def ==(other)
      other.is_a?(SecretReference) && other.name == name
    end
    alias_method :eql?, :==

    # Returns a hash code based on the secret name.
    #
    # @return [Integer] The hash code.
    def hash
      [self.class, name].hash
    end

    # Returns a string representation of the reference. Only the name is shown,
    # because the reference has no value.
    #
    # @return [String] The string representation.
    def inspect
      "#<PatientHttp::SecretReference name=#{name.inspect}>"
    end
  end
end
