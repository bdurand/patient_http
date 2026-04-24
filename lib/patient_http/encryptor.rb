# frozen_string_literal: true

module PatientHttp
  # Handles encryption and decryption of payloads for secure storage.
  #
  # This class provides a simple interface for encrypting data before storage and
  # decrypting it after retrieval. It supports pluggable encryption and decryption
  # logic, allowing you to use any encryption library or method that fits your needs.
  class Encryptor
    # Initialize a new Encryptor with optional encryption and decryption callables.
    #
    # @param encryption [#call, nil] A callable object that takes data and returns encrypted data
    # @param decryption [#call, nil] A callable object that takes encrypted data and returns decrypted data
    def initialize(encryption: nil, decryption: nil)
      @encryption = encryption
      @decryption = decryption
    end

    # Encrypt data using the provided encryption callable. If no encryption callable is set,
    # returns the original data.
    #
    # @param data [Hash] The data to be encrypted
    # @return [Hash, nil] The encrypted data as a hash or the original data if no encryption callable is set
    # @raise [JSON::GeneratorError] If the data cannot be serialized to JSON
    def encrypt(data)
      return nil if data.nil?

      raise ArgumentError.new("Data is not a Hash") unless data.is_a?(Hash)

      return data unless @encryption

      json = JSON.generate(data)

      {
        "__encrypted__" => true,
        "value" => base64_encode(@encryption.call(json))
      }
    end

    # Decrypt data using the provided decryption callable. If no decryption callable is set,
    # or if the data is not marked as encrypted, returns the original data.
    #
    # @param data [Hash] The data to be decrypted
    # @return [Hash, nil] The decrypted data as a hash or the original data if no decryption callable
    #   is set or if data is not encrypted
    # @raise [JSON::ParserError] If the decrypted data cannot be parsed as JSON
    def decrypt(data)
      return nil if data.nil?

      raise ArgumentError.new("Data is not a Hash") unless data.is_a?(Hash)

      return data unless @decryption && data["__encrypted__"]
      return nil if data["value"].nil?

      decrypted = @decryption.call(base64_decode(data["value"]))
      JSON.parse(decrypted)
    end

    private

    def base64_encode(data)
      [data].pack("m0")
    end

    def base64_decode(data)
      data.unpack1("m")
    end
  end
end
