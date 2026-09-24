# frozen_string_literal: true

module PatientHttp
  # Reads and decodes HTTP response bodies.
  #
  # Reading runs on the reactor thread. It collects the raw body chunks, which
  # might be compressed, and validates their size. Decoding is a separate step
  # that joins the chunks, inflates compressed content, and applies the charset.
  # Decoding runs on a completion worker thread, so it doesn't block the event
  # loop.
  class ResponseReader
    # Raised when a body read is aborted because the processor was stopped after
    # its shutdown deadline. The shutdown sequence re-enqueues the task, so this
    # error is handled internally and never reaches callbacks.
    #
    # @api private
    class ReadAbortedError < StandardError; end

    # Maps the content encodings that are inflated during decoding to the window
    # bits of each wire format that the encoding can arrive in. Formats are tried
    # in order until one inflates the body.
    #
    # RFC 9110 specifies the zlib format for `deflate`, so a `deflate` body should
    # have a zlib header. Some servers send a raw deflate stream instead, so the
    # raw format is a fallback.
    INFLATE_WINDOW_BITS = {
      "gzip" => [Zlib::MAX_WBITS | 16].freeze,
      "deflate" => [Zlib::MAX_WBITS, -Zlib::MAX_WBITS].freeze
    }.freeze

    # The content encoding that means the body isn't encoded. It needs no
    # decoding, but the reader must recognize it so it doesn't stop decoding of
    # the encodings applied before it.
    IDENTITY_ENCODING = "identity"

    class << self
      # Splits the encodings in the `content-encoding` header into the ones that
      # stay applied to the body and the ones that can be decoded.
      #
      # A body can have more than one encoding. The header lists them in the order
      # they were applied, so decoding runs from the last name backward. Decoding
      # stops at the first name it doesn't recognize. Every encoding before that
      # point stays applied to the body.
      #
      # @param headers_hash [Hash] The response headers.
      # @return [Array(Array<String>, Array<String>)] The encodings that remain
      #   applied and the encodings that can be decoded, both in applied order.
      def split_encodings(headers_hash)
        encodings = content_encodings(headers_hash)
        boundary = encodings.rindex { |name| !decodable?(name) }
        return [[], encodings] if boundary.nil?

        [encodings[0..boundary], encodings[(boundary + 1)..]]
      end

      # Parses the `content-encoding` header into encoding names.
      #
      # @param headers_hash [Hash] The response headers.
      # @return [Array<String>] The lowercase encoding names, in applied order.
      def content_encodings(headers_hash)
        headers_hash["content-encoding"].to_s.split(",").filter_map do |name|
          name = name.strip.downcase
          name unless name.empty?
        end
      end

      # Returns `true` if the reader can remove an encoding.
      #
      # @param name [String] A lowercase content encoding name.
      # @return [Boolean] `true` if the reader can remove this encoding.
      def decodable?(name)
        name == IDENTITY_ENCODING || INFLATE_WINDOW_BITS.key?(name)
      end

      # Rewrites the `content-encoding` header for a decoded body. If no encodings
      # remain, the header is removed. Otherwise, the header lists only the
      # encodings that the reader couldn't remove. The header always describes the
      # body delivered with it.
      #
      # @param headers_hash [Hash] The response headers.
      # @return [Hash] The headers with `content-encoding` updated or removed.
      def rewrite_content_encoding(headers_hash)
        return headers_hash unless headers_hash.key?("content-encoding")

        remaining, _decodable = split_encodings(headers_hash)

        if remaining.empty?
          headers_hash.except("content-encoding")
        else
          headers_hash.merge("content-encoding" => remaining.join(", "))
        end
      end
    end

    # Creates a reader.
    #
    # Reading needs a processor, so it can abort after the processor passes its
    # shutdown deadline. Decoding needs only the configuration, so a caller that
    # does its own reading can pass only the configuration.
    #
    # @param processor [Processor, nil] The processor.
    # @param config [Configuration, nil] The configuration. Defaults to the processor's
    #   configuration.
    def initialize(processor, config: nil)
      @processor = processor
      @config = config || processor.config
    end

    # Reads the raw response body chunks and validates their size.
    #
    # This method reads the whole response body asynchronously, so the connection
    # can be reused. The async-http client handles connection pooling and
    # keepalive. Iterating over the body instead of calling `read` keeps the I/O
    # non-blocking, so it yields to the reactor. The chunks are the bytes as
    # received. If the response is compressed, this size check applies to the
    # compressed bytes, and {#decode_body} applies the same limit to the inflated
    # bytes.
    #
    # The `Content-Length` header is checked against the size limit before the
    # read starts. A response to a `HEAD` request has an empty body but reports
    # the `Content-Length` of the resource, so the header check is skipped when
    # the body reports that it's empty.
    #
    # @param async_response [Async::HTTP::Protocol::Response] The async HTTP response.
    # @param headers_hash [Hash] The response headers.
    # @return [Array<String>, nil] The raw body chunks, or `nil` if there is no body.
    # @raise [ResponseTooLargeError] If the body exceeds `max_response_size`.
    # @raise [ReadAbortedError] If the processor stopped after its shutdown deadline
    #   during the read.
    def read_raw_body(async_response, headers_hash)
      body = async_response.body
      return nil unless body

      validate_content_length(headers_hash) unless body.empty?
      read_body_chunks(async_response)
    end

    # Decodes raw body chunks into the final body string.
    #
    # This method joins the chunks, inflates gzip and deflate content, and applies
    # the charset from the `Content-Type` header. It enforces `max_response_size`
    # on the inflated bytes. This work is CPU-bound and runs on a completion
    # worker thread.
    #
    # If the reader doesn't support an encoding, the body stays encoded. A body
    # that is still encoded keeps its binary encoding, because the charset
    # doesn't describe it. Use {.split_encodings} to find the encodings that stay
    # applied, so the `content-encoding` header delivered with the response
    # describes its body.
    #
    # @param chunks [Array<String>, nil] The raw body chunks.
    # @param headers_hash [Hash] The response headers.
    # @return [String, nil] The decoded body, or `nil` if there is no body.
    # @raise [ResponseTooLargeError] If the inflated body exceeds `max_response_size`.
    def decode_body(chunks, headers_hash)
      return nil if chunks.nil?

      remaining, decodable = self.class.split_encodings(headers_hash)
      warn_undecodable(remaining) unless remaining.empty?

      body = inflate_encodings(chunks, decodable).join
      body.force_encoding(Encoding::ASCII_8BIT)
      # A body that is still encoded is not text yet, so the charset does not
      # describe its bytes. Leave it binary for the caller to decode.
      return body unless remaining.empty?

      apply_charset_encoding(body, headers_hash)
    end

    private

    # Removes the given encodings from the body, starting with the one applied
    # last. `identity` needs no work. Every other encoding is inflated.
    #
    # @param chunks [Array<String>] The encoded body chunks.
    # @param encodings [Array<String>] The decodable encoding names, in applied order.
    # @return [Array<String>] The decoded chunks.
    # @raise [ResponseTooLargeError] If the inflated body exceeds `max_response_size`.
    def inflate_encodings(chunks, encodings)
      encodings.reverse_each do |name|
        chunks = [inflate_encoding(chunks, name)] if INFLATE_WINDOW_BITS.key?(name)
      end

      chunks
    end

    # Inflates one encoding by trying each wire format that the encoding can use.
    # All the chunks are in memory, so if a format is wrong, the next format
    # starts again from the beginning of the body.
    #
    # @param chunks [Array<String>] The encoded body chunks.
    # @param name [String] A lowercase content encoding name.
    # @return [String] The inflated body.
    # @raise [Zlib::Error] If no format can inflate the body.
    # @raise [ResponseTooLargeError] If the inflated body exceeds `max_response_size`.
    def inflate_encoding(chunks, name)
      formats = INFLATE_WINDOW_BITS.fetch(name)
      last_index = formats.size - 1

      formats.each_with_index do |window_bits, index|
        return inflate_chunks(chunks, window_bits)
      rescue Zlib::DataError, Zlib::BufError
        raise if index == last_index
      end
    end

    # Logs a warning for encodings that couldn't be removed. The body is still
    # delivered with its `content-encoding` header, so the caller can decode it.
    # The warning records that the server ignored the `accept-encoding` header.
    #
    # @param remaining [Array<String>] The encodings left on the body.
    # @return [void]
    def warn_undecodable(remaining)
      logger&.warn(
        "[PatientHttp] Cannot decode response body with content-encoding " \
        "'#{remaining.join(", ")}'; returning the encoded body"
      )
      nil
    end

    def max_response_size
      @config.max_response_size
    end

    def logger
      @config.logger
    end

    # Validates that the `content-length` header doesn't exceed the maximum size.
    #
    # @param headers_hash [Hash] The response headers.
    # @raise [ResponseTooLargeError] If `content-length` exceeds `max_response_size`.
    def validate_content_length(headers_hash)
      content_length = headers_hash["content-length"]&.to_i
      if content_length && content_length > max_response_size
        raise ResponseTooLargeError.new(
          "Response body size (#{content_length} bytes) exceeds maximum allowed size (#{max_response_size} bytes)"
        )
      end
    end

    # Reads body chunks and checks their size.
    #
    # @param async_response [Async::HTTP::Protocol::Response] The async HTTP response.
    # @return [Array<String>] The raw body chunks.
    # @raise [ResponseTooLargeError] If the body size exceeds `max_response_size` during
    #   the read.
    # @raise [ReadAbortedError] If the processor stopped after its shutdown deadline
    #   during the read.
    def read_body_chunks(async_response)
      chunks = []
      total_size = 0
      finished = false

      begin
        async_response.body.each do |chunk|
          # Abort the read once the processor has passed its shutdown deadline.
          # Reads are allowed to finish while the processor is merely stopping
          # (the graceful shutdown window) so in-flight responses can still be
          # delivered.
          if @processor&.stopped?
            raise ReadAbortedError.new("Processor stopped while reading response body")
          end

          total_size += chunk.bytesize

          if total_size > max_response_size
            raise ResponseTooLargeError.new(
              "Response body size exceeded maximum allowed size (#{max_response_size} bytes)"
            )
          end

          chunks << chunk
        end

        finished = true

        chunks
      ensure
        # Always close the body if we were interrupted or if an error occurred
        # This ensures the connection is properly released back to the pool
        async_response.body.close unless finished
      end
    end

    # Inflates compressed body chunks and enforces the size limit as it streams,
    # so a small compressed body can't expand past `max_response_size`.
    #
    # @param chunks [Array<String>] The raw compressed chunks.
    # @param window_bits [Integer] The zlib window bits for the content encoding.
    # @return [String] The inflated body.
    # @raise [ResponseTooLargeError] If the inflated size exceeds `max_response_size`.
    def inflate_chunks(chunks, window_bits)
      # A response can declare a content encoding and still carry no body.
      # There is nothing to inflate, and finishing an empty stream would
      # raise a buffer error.
      return +"" if chunks.all?(&:empty?)

      inflater = Zlib::Inflate.new(window_bits)
      body = +""

      begin
        # The block form yields the inflated output in buffer-sized pieces, so
        # the size is checked before the whole expansion is materialized. A
        # single small compressed chunk can otherwise inflate to gigabytes
        # before any check runs.
        appender = ->(output) do
          body << output
          validate_inflated_size(body)
        end

        chunks.each { |chunk| inflater.inflate(chunk, &appender) }
        inflater.finish(&appender) unless inflater.finished?
      ensure
        inflater.close
      end

      body
    end

    def validate_inflated_size(body)
      if body.bytesize > max_response_size
        raise ResponseTooLargeError.new(
          "Response body size exceeded maximum allowed size (#{max_response_size} bytes)"
        )
      end
    end

    # Extracts the charset from the `Content-Type` header.
    #
    # @param headers_hash [Hash] The response headers.
    # @return [String, nil] The charset name, or `nil` if it isn't specified.
    def extract_charset(headers_hash)
      content_type = headers_hash["content-type"]
      return nil unless content_type

      match = content_type.match(/;\s*charset\s*=\s*([^;\s]+)/i)
      return nil unless match

      charset = match[1].strip
      charset.gsub(/\A["']|["']\z/, "")
    end

    # Applies the charset encoding to the response body.
    #
    # This method sets the string encoding from the charset in the `Content-Type`
    # header. If the charset is invalid or unrecognized, it falls back to ASCII-8BIT.
    #
    # @param body [String] The response body.
    # @param headers_hash [Hash] The response headers.
    # @return [String] The body with its encoding set.
    def apply_charset_encoding(body, headers_hash)
      return body unless body

      charset = extract_charset(headers_hash)
      return body unless charset

      begin
        encoding = Encoding.find(charset)
        body.force_encoding(encoding)
      rescue ArgumentError
        logger&.warn("[PatientHttp] Unknown charset '#{charset}' in Content-Type header")
        body
      end
    end
  end
end
