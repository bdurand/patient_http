# frozen_string_literal: true

module PatientHttp
  # Encodes and decodes HTTP response bodies for storage.
  #
  # This class applies a compression and encoding strategy for each content type, to
  # keep the storage and the transmission of response data efficient.
  class Payload
    # @return [Symbol] The encoding type.
    attr_reader :encoding

    # @return [String] The encoded data.
    attr_reader :encoded_value

    # @return [String, nil] The character set, if one applies.
    attr_reader :charset

    class << self
      # Reconstructs a Payload from a hash representation.
      #
      # @param hash [Hash, nil] A hash with the keys `"encoding"` and `"value"`.
      # @return [Payload, nil] The reconstructed payload, or nil if the hash is not
      #   valid.
      def load(hash)
        return nil if hash.nil? || hash["value"].nil?

        new(hash["encoding"].to_sym, hash["value"], hash["charset"])
      end

      # Encodes a value based on its MIME type.
      #
      # For a text content type, this method applies gzip compression when that makes
      # the value smaller. For binary content, it uses Base64 encoding. A value that a
      # text MIME type claims is text, but that does not hold text, is also encoded as
      # binary, because the serialized form must survive JSON encoding.
      #
      # @param value [String] The value to encode.
      # @param mimetype [String, nil] The MIME type of the content.
      # @return [Array(Symbol, String, String), nil] The encoding, the encoded value,
      #   and the charset, or nil if the value is nil.
      def encode(value, mimetype)
        return nil if value.nil?

        if is_text_mimetype?(mimetype)
          text = text_value(value, charset(mimetype))
          return encode_text(text) if text?(text)
        end

        [:binary, [value].pack("m0"), Encoding::BINARY.name]
      end

      # Decodes an encoded value based on its encoding type.
      #
      # @param encoded_value [String] The encoded data.
      # @param encoding [Symbol] The encoding type: `:text`, `:binary`, or `:gzipped`.
      # @param charset [String, nil] The character set, if one applies.
      # @return [String, nil] The decoded value, or nil if the encoded value is nil.
      def decode(encoded_value, encoding, charset)
        return nil if encoded_value.nil?

        decoded_value = case encoding
        when :text
          encoded_value
        when :binary
          encoded_value.unpack1("m")
        when :gzipped
          Zlib.gunzip(encoded_value.unpack1("m"))
        end

        force_encoding(decoded_value, charset)
      end

      private

      # Encodes a text value, and compresses it when that makes it smaller.
      #
      # @param value [String] The text to encode.
      # @return [Array(Symbol, String, String)] The encoding, the encoded value, and
      #   the charset.
      def encode_text(value)
        return [:text, value, value.encoding.name] if value.bytesize < 4096

        gzipped = Zlib.gzip(value)
        if gzipped.bytesize < value.bytesize
          [:gzipped, [gzipped].pack("m0"), value.encoding.name]
        else
          [:text, value, value.encoding.name]
        end
      end

      # Checks whether a value can be serialized as text. JSON encoding converts a
      # string to UTF-8, so the value must either be valid text in its own encoding or
      # hold bytes that are already valid UTF-8. A body that still carries a content
      # encoding that the reader could not decode holds neither, even though its MIME
      # type names a text type.
      #
      # @param value [String] The value to check.
      # @return [Boolean] Whether the value can be serialized as text.
      def text?(value)
        return value.valid_encoding? unless value.encoding == Encoding::BINARY
        return true if value.ascii_only?

        value.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      end

      def is_text_mimetype?(mimetype)
        mimetype&.match?(/\Atext\/|application\/(?:json|xml|javascript)/)
      end

      def charset(mimetype)
        return Encoding::ASCII_8BIT.name if mimetype.nil?

        match = mimetype.match(/charset=([\w-]+)/)
        return Encoding::ASCII_8BIT.name unless match

        begin
          Encoding.find(match[1]).name
        rescue
          Encoding::ASCII_8BIT.name
        end
      end

      # Returns the value as a UTF-8 encoded string when that is possible. If the
      # value cannot be converted to UTF-8, it is returned in the response charset or
      # in ASCII-8BIT.
      #
      # The encoding strategy is:
      #
      # 1. Force-encode the value to the response charset.
      # 2. Transcode it to UTF-8 to make storage more efficient.
      # 3. If the transcoding fails, keep the charset encoding.
      # 4. If the force-encoding itself fails, fall back to ASCII-8BIT.
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
    # @param encoding [Symbol] The encoding type.
    # @param encoded_value [String] The encoded data.
    # @param charset [String, nil] The character set, if one applies.
    def initialize(encoding, encoded_value, charset)
      @encoded_value = encoded_value
      @encoding = encoding
      @charset = charset
    end

    # Returns the decoded value.
    #
    # @return [String, nil] The decoded data.
    def value
      self.class.decode(encoded_value, encoding, charset)
    end

    # Converts the payload to a hash representation for serialization.
    #
    # @return [Hash] A hash with the keys `"encoding"`, `"value"`, and `"charset"`.
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
