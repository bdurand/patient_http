# frozen_string_literal: true

module PatientHttp
  # A reference to a named secret that can be used as a header or query parameter
  # value when building a {Request}.
  #
  # A SecretReference holds only the secret's name -- never its value. When a request
  # is serialized (for example, to be enqueued in a job system), the reference is
  # serialized as a lightweight marker (`{"$secret" => name}`) so the sensitive value
  # is never written to the queue or logs. The actual value is resolved on the
  # processor side at the moment the request is sent, using the secrets registered on
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

    # @return [String] the name of the referenced secret
    attr_reader :name

    class << self
      # Check if a value is a secret reference (either a SecretReference instance or a
      # serialized marker hash).
      #
      # @param value [Object] the value to check
      # @return [Boolean] true if the value is a secret reference
      def reference?(value)
        value.is_a?(SecretReference) ||
          (value.is_a?(Hash) && value.key?(REFERENCE_KEY))
      end

      # Reconstruct a SecretReference from a serialized marker hash. Any other value
      # (including an existing SecretReference) is returned unchanged.
      #
      # @param value [Object] a serialized marker hash or any other value
      # @return [Object] a SecretReference for a marker hash, otherwise the original value
      def load(value)
        return value unless value.is_a?(Hash) && value.key?(REFERENCE_KEY)

        new(value[REFERENCE_KEY])
      end
    end

    # Initialize a new SecretReference.
    #
    # @param name [String, Symbol] the name of the secret to reference
    # @raise [ArgumentError] if the name is empty
    def initialize(name)
      @name = name.to_s
      raise ArgumentError.new("secret name cannot be empty") if @name.empty?
    end

    # Serialize to a marker hash. Only the name is included; the value is never present.
    #
    # @return [Hash] the marker hash
    def as_json
      {REFERENCE_KEY => name}
    end

    def ==(other)
      other.is_a?(SecretReference) && other.name == name
    end
    alias_method :eql?, :==

    def hash
      [self.class, name].hash
    end

    # Inspect the reference. Only the name is shown (there is no value to leak).
    #
    # @return [String]
    def inspect
      "#<PatientHttp::SecretReference name=#{name.inspect}>"
    end
  end
end
