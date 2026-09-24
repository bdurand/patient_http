# frozen_string_literal: true

module PatientHttp
  # Encodes and decodes HTTP response bodies for storage.
  #
  # This class chooses a compression and encoding strategy for each content type
  # to reduce the size of stored and transmitted response data.
  class Payload
    # @return [Symbol] The encoding type.
    attr_reader :encoding

    # @return [String] The encoded data.
    attr_reader :encoded_value

    # @return [String, nil] The character set, if there is one.
    attr_reader :charset

    class << self
      # Reconstructs a payload from a hash.
      #
      # @param hash [Hash, nil] A hash with the keys `"encoding"` and `"value"`.
      # @return [Payload, nil] The reconstructed payload, or `nil` if the hash is invalid.
      def load(hash)
        return nil if hash.nil? || hash["value"].nil?

        new(hash["encoding"].to_sym, hash["value"], hash["charset"])
      end

      # Encodes a value based on its MIME type.
      #
      # Text content is compressed with gzip if that makes it smaller. Binary
      # content is Base64 encoded. If a value has a text MIME type but doesn't hold
      # text, it's also encoded as binary, because the serialized form must survive
      # JSON encoding.
      #
      # @param value [String] The value to encode.
      # @param mimetype [String, nil] The MIME type of the content.
      # @return [Array(Symbol, String, String), nil] An array of `[encoding, encoded_value,
      #   charset]`, or `nil` if the value is `nil`.
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
      # @param charset [String, nil] The character set, if there is one.
      # @return [String, nil] The decoded value, or `nil` if `encoded_value` is `nil`.
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

      # Encodes a text value and compresses it if that makes it smaller.
      #
      # @param value [String] The text to encode.
      # @return [Array(Symbol, String, String)] An array of `[encoding, encoded_value, charset]`.
      def encode_text(value)
        return [:text, value, value.encoding.name] if value.bytesize < 4096

        gzipped = Zlib.gzip(value)
        if gzipped.bytesize < value.bytesize
          [:gzipped, [gzipped].pack("m0"), value.encoding.name]
        else
          [:text, value, value.encoding.name]
        end
      end

      # Returns `true` if a value can be serialized as text. JSON encoding converts
      # a string to UTF-8, so the value must be valid text in its own encoding or
      # hold bytes that are already valid UTF-8. A body that still has a content
      # encoding that the reader couldn't decode is neither, even if its MIME type
      # is a text type.
      #
      # @param value [String] The value to check.
      # @return [Boolean]
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

      # Returns the value as a UTF-8 string if possible. If the value can't be
      # converted to UTF-8, returns it in the response charset or in ASCII-8BIT.
      #
      # This method uses the following steps:
      #
      # 1. Force the encoding to the response charset.
      # 2. Try to transcode the value to UTF-8, which stores more efficiently.
      # 3. If transcoding fails, keep the charset encoding.
      # 4. If forcing the encoding fails, fall back to ASCII-8BIT.
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

    # Creates a payload.
    #
    # @param encoding [Symbol] The encoding type.
    # @param encoded_value [String] The encoded data.
    # @param charset [String, nil] The character set, if there is one.
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

    # Converts the payload to a hash for serialization.
    #
    # @return [Hash] A hash with the keys `"encoding"` and `"value"`.
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
