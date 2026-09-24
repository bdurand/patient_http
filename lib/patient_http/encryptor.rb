# frozen_string_literal: true

module PatientHttp
  # Encrypts payloads before they're stored in a job queue, and decrypts them
  # after they're read.
  #
  # The encryptor serializes a hash to JSON, passes the bytes to the encryption
  # callable, and stores the Base64-encoded result as
  # `{"__encrypted__" => true, "value" => "<base64>"}`. You can use any
  # encryption library.
  #
  # @see Configuration#encryptor
  class Encryptor
    # Creates an encryptor. Without callables, the encryptor returns data
    # unchanged.
    #
    # @param encryption [#call, nil] An object that takes the bytes as a String
    #   and returns the encrypted bytes.
    # @param decryption [#call, nil] An object that takes the encrypted bytes and
    #   returns the decrypted bytes.
    def initialize(encryption: nil, decryption: nil)
      @encryption = encryption
      @decryption = decryption
    end

    # Encrypts a hash. If no encryption callable is set, the hash is returned
    # unchanged.
    #
    # @param data [Hash, nil] The data to encrypt.
    # @return [Hash, nil] The encrypted data, or the original data if no
    #   encryption callable is set.
    # @raise [ArgumentError] If the data isn't a Hash or `nil`.
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

    # Decrypts a hash. If no decryption callable is set, or if the hash isn't
    # encrypted, the hash is returned unchanged. As a result, data written
    # before encryption was turned on can still be read.
    #
    # @param data [Hash, nil] The data to decrypt.
    # @return [Hash, nil] The decrypted data, or the original data.
    # @raise [ArgumentError] If the data isn't a Hash or `nil`.
    # @raise [JSON::ParserError] If the decrypted data isn't valid JSON.
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
