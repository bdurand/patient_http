# frozen_string_literal: true

module PatientHttp
  # Encrypts payloads before storage and decrypts them after retrieval.
  #
  # You provide the encryption and decryption logic as callables, so you can use
  # any encryption library.
  class Encryptor
    # Creates an encryptor with optional encryption and decryption callables.
    #
    # @param encryption [#call, nil] A callable that takes data and returns encrypted data.
    # @param decryption [#call, nil] A callable that takes encrypted data and returns decrypted data.
    def initialize(encryption: nil, decryption: nil)
      @encryption = encryption
      @decryption = decryption
    end

    # Encrypts data with the encryption callable. If no encryption callable is set,
    # returns the original data.
    #
    # @param data [Hash] The data to encrypt.
    # @return [Hash, nil] The encrypted data as a hash, or the original data if no
    #   encryption callable is set.
    # @raise [JSON::GeneratorError] If the data can't be serialized to JSON.
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

    # Decrypts data with the decryption callable. If no decryption callable is set,
    # or if the data isn't marked as encrypted, returns the original data.
    #
    # @param data [Hash] The data to decrypt.
    # @return [Hash, nil] The decrypted data as a hash, or the original data if no
    #   decryption callable is set or the data isn't encrypted.
    # @raise [JSON::ParserError] If the decrypted data can't be parsed as JSON.
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
