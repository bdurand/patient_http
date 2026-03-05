# frozen_string_literal: true

module PatientHttp
  # Handles encoding and decoding of HTTP response bodies for storage.
  #
  # This class provides compression and encoding strategies for different content types
  # to optimize storage and transmission of response data.
  class Payload
    # @return [Symbol] the encoding type
    attr_reader :encoding

    # @return [String] the encoded data
    attr_reader :encoded_value

    # @return [String, nil] the character set (if applicable)
    attr_reader :charset

    class << self
      # Reconstructs a Payload from a hash representation.
      #
      # @param hash [Hash, nil] hash with "encoding" and "value" keys
      # @return [Payload, nil] reconstructed payload or nil if hash is invalid
      def load(hash)
        return nil if hash.nil? || hash["value"].nil?

        new(hash["encoding"].to_sym, hash["value"], hash["charset"])
      end

      # Encodes a value based on its MIME type.
      #
      # For text-based content types, applies gzip compression if beneficial.
      # For binary content, uses Base64 encoding.
      #
      # @param value [String] the value to encode
      # @param mimetype [String, nil] the MIME type of the content
      # @return [Array(Symbol, String, String), nil] [encoding, encoded_value, charset] or nil if value is nil
      def encode(value, mimetype)
        return nil if value.nil?

        if is_text_mimetype?(mimetype)
          value = text_value(value, charset(mimetype))

          if value.bytesize < 4096
            [:text, value, value.encoding.name]
          else
            gzipped = Zlib::Deflate.deflate(value)
            if gzipped.bytesize < value.bytesize
              [:gzipped, [gzipped].pack("m0"), value.encoding.name]
            else
              [:text, value, value.encoding.name]
            end
          end
        else
          [:binary, [value].pack("m0"), Encoding::BINARY.name]
        end
      end

      # Decodes an encoded value based on its encoding type.
      #
      # @param encoded_value [String] the encoded data
      # @param encoding [Symbol] the encoding type (:text, :binary, :gzipped)
      # @param charset [String, nil] the character set (if applicable)
      # @return [String, nil] the decoded value or nil if encoded_value is nil
      def decode(encoded_value, encoding, charset)
        return nil if encoded_value.nil?

        decoded_value = case encoding
        when :text
          encoded_value
        when :binary
          encoded_value.unpack1("m")
        when :gzipped
          Zlib::Inflate.inflate(encoded_value.unpack1("m"))
        end

        force_encoding(decoded_value, charset)
      end

      private

      def is_text_mimetype?(mimetype)
        mimetype&.match?(/\Atext\/|application\/(?:json|xml|javascript)/)
      end

      def charset(mimetype)
        return Encoding::ASCII_8BIT.name if mimetype.nil?

        match = mimetype.match(/charset=([\w-]+)/)
        return Encoding::ASCII_8BIT.name unless match

        begin
          Encoding.find(match[1])
        rescue
          Encoding::ASCII_8BIT.name
        end
      end

      # Return the value as a UTF-8 encoded string if possible. If the value cannot
      # be converted to UTF-8, return it in the response charset or ASCII-8BIT.
      def text_value(value, charset)
        text = force_encoding(value, charset)
        unless text.encoding == Encoding::UTF_8
          begin
            text = text.encode(Encoding::UTF_8)
          rescue
            # Ignore if cannot convert to UTF-8
          end
        end
        text
      rescue
        force_encoding(value, Encoding::ASCII_8BIT.name)
      end

      def force_encoding(value, charset)
        return value if value.nil? || value.encoding.names.include?(charset)

        charset ||= Encoding::ASCII_8BIT.name
        value = value.dup if value.frozen?
        value.force_encoding(charset)
      end
    end

    # Initializes a new Payload.
    #
    # @param encoding [Symbol] the encoding type
    # @param encoded_value [String] the encoded data
    # @param charset [String, nil] the character set (if applicable)
    def initialize(encoding, encoded_value, charset)
      @encoded_value = encoded_value
      @encoding = encoding
      @charset = charset
    end

    # Returns the decoded value.
    #
    # @return [String, nil] the decoded data
    def value
      self.class.decode(encoded_value, encoding, charset)
    end

    # Converts to a hash representation for serialization.
    #
    # @return [Hash] hash with "encoding" and "value" keys
    def as_json
      {
        "encoding" => encoding.to_s,
        "value" => encoded_value,
        "charset" => charset
      }
    end

    alias_method :dump, :as_json
  end
end
