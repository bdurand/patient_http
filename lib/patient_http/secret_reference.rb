# frozen_string_literal: true

module PatientHttp
  # A reference to a named secret. Use it as a header or query parameter value
  # in a {Request}. Create one with {PatientHttp.secret}.
  #
  # The reference holds only the name of the secret, not its value. A
  # serialized request stores the marker `{"$secret" => name}`, so the value
  # isn't written to the job queue or to logs. The processor resolves the value
  # from the secrets registered in the {Configuration} when it sends the
  # request.
  #
  # @example Refer to secrets in a request
  #   PatientHttp.get(
  #     "https://api.example.com/data",
  #     callback: MyCallback,
  #     headers: {"Authorization" => PatientHttp.secret(:api_token)},
  #     params: {"api_key" => PatientHttp.secret(:api_key)}
  #   )
  class SecretReference
    # The key that identifies a secret reference in serialized JSON.
    REFERENCE_KEY = "$secret"

    # @return [String] The secret name.
    attr_reader :name

    class << self
      # Returns whether a value is a secret reference. The value can be a
      # `SecretReference` or a serialized marker hash.
      #
      # @param value [Object] The value to check.
      # @return [Boolean] `true` if the value is a secret reference.
      def reference?(value)
        value.is_a?(SecretReference) ||
          (value.is_a?(Hash) && value.key?(REFERENCE_KEY))
      end

      # Creates a reference from a serialized marker hash. Other values are
      # returned unchanged.
      #
      # @param value [Object] A serialized marker hash, or any other value.
      # @return [Object] A `SecretReference` for a marker hash, or the value.
      def load(value)
        return value unless value.is_a?(Hash) && value.key?(REFERENCE_KEY)

        new(value[REFERENCE_KEY])
      end
    end

    # Creates a reference.
    #
    # @param name [String, Symbol] The secret name.
    # @raise [ArgumentError] If the name is empty.
    def initialize(name)
      @name = name.to_s
      raise ArgumentError.new("secret name cannot be empty") if @name.empty?
    end

    # Returns the reference as a marker hash. The hash has the name, not the
    # value.
    #
    # @return [Hash] The marker hash.
    def as_json
      {REFERENCE_KEY => name}
    end

    # Returns whether another object is a reference to the same secret.
    #
    # @param other [Object] The object to compare.
    # @return [Boolean] `true` if the names are equal.
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

    # Returns a description of the reference. It shows only the name.
    #
    # @return [String] The description.
    def inspect
      "#<PatientHttp::SecretReference name=#{name.inspect}>"
    end
  end
end
