# frozen_string_literal: true

module PatientHttp
  # Reads and decodes HTTP response bodies.
  #
  # Reading happens on the reactor thread. It collects the raw, possibly compressed,
  # body chunks and validates their size. Decoding—joining the chunks, inflating
  # compressed content, and applying the charset—is a separate step, so that it can
  # run on a completion worker thread instead of blocking the event loop.
  class ResponseReader
    # Raised when a body read is stopped because the processor was stopped past its
    # shutdown deadline. The shutdown sequence re-enqueues the task, so this error is
    # handled internally and never reaches a callback.
    #
    # @api private
    class ReadAbortedError < StandardError; end

    # Content encodings that are inflated during decoding, mapped to the window bits of
    # each wire format that the encoding can arrive in. The formats are tried in order
    # until one of them inflates the body.
    #
    # A "deflate" body must carry a zlib header, because RFC 9110 specifies the zlib
    # format. Some servers send a bare deflate stream instead, so the raw format is
    # kept as a fallback.
    INFLATE_WINDOW_BITS = {
      "gzip" => [Zlib::MAX_WBITS | 16].freeze,
      "deflate" => [Zlib::MAX_WBITS, -Zlib::MAX_WBITS].freeze
    }.freeze

    # Content encoding that means that the body was not encoded at all. It needs no
    # work to decode, but it must still be recognized, so that it does not stop the
    # decoding of the encodings that were applied before it.
    IDENTITY_ENCODING = "identity"

    class << self
      # Splits the encodings that the content-encoding header names into the ones that
      # stay applied to the body and the ones that can be decoded.
      #
      # A body can carry more than one encoding. The encodings are listed in the order
      # in which they were applied, so decoding starts at the last name, runs
      # backwards, and stops at the first name that it does not recognize. Every
      # encoding before that point stays applied to the body.
      #
      # @param headers_hash [Hash] The response headers.
      # @return [Array(Array<String>, Array<String>)] The encodings that stay applied
      #   and the encodings that can be decoded, both in the order in which they were
      #   applied.
      def split_encodings(headers_hash)
        encodings = content_encodings(headers_hash)
        boundary = encodings.rindex { |name| !decodable?(name) }
        return [[], encodings] if boundary.nil?

        [encodings[0..boundary], encodings[(boundary + 1)..]]
      end

      # Parses the content-encoding header into encoding names.
      #
      # @param headers_hash [Hash] The response headers.
      # @return [Array<String>] The lowercase encoding names, in the order in which
      #   they were applied.
      def content_encodings(headers_hash)
        headers_hash["content-encoding"].to_s.split(",").filter_map do |name|
          name = name.strip.downcase
          name unless name.empty?
        end
      end

      # Checks whether the reader can remove a content encoding.
      #
      # @param name [String] A lowercase content encoding name.
      # @return [Boolean] Whether the reader can remove this encoding.
      def decodable?(name)
        name == IDENTITY_ENCODING || INFLATE_WINDOW_BITS.key?(name)
      end

      # Restates the content-encoding header for a decoded body. The header is removed
      # when no encoding is left applied. Otherwise it names only the encodings that
      # the reader could not remove, so that the header always describes the body that
      # is delivered with it.
      #
      # @param headers_hash [Hash] The response headers.
      # @return [Hash] The headers, with the content-encoding header updated or
      #   removed.
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

    # Initializes a new ResponseReader.
    #
    # Reading needs a processor, so that it can stop once the processor is past its
    # shutdown deadline. Decoding needs only the configuration, so a caller that does
    # its own reading can supply the configuration instead.
    #
    # @param processor [Processor, nil] The processor.
    # @param config [Configuration, nil] The configuration. Defaults to the
    #   configuration of the processor.
    def initialize(processor, config: nil)
      @processor = processor
      @config = config || processor.config
    end

    # Reads the raw response body chunks and validates their size.
    #
    # This method reads the async HTTP response body asynchronously to completion, so
    # that the connection can be reused. The async-http client handles the connection
    # pooling and the keep-alive internally. Iteration is used instead of `read`,
    # which keeps the I/O non-blocking and yields to the reactor.
    #
    # The chunks are the wire bytes. When the response is compressed, the size check
    # here applies to the compressed bytes, and {#decode_body} applies the same limit
    # to the inflated bytes.
    #
    # The Content-Length header is checked against the size limit before the read
    # starts. A response to a HEAD request has an empty body but reports the
    # Content-Length of the resource, so the header check is skipped when the body
    # reports itself as empty.
    #
    # @param async_response [Async::HTTP::Protocol::Response] The async HTTP response.
    # @param headers_hash [Hash] The response headers.
    # @return [Array<String>, nil] The raw body chunks, or nil if there is no body.
    # @raise [ResponseTooLargeError] If the body is larger than `max_response_size`.
    # @raise [ReadAbortedError] If the processor stopped past its shutdown deadline
    #   during the read.
    def read_raw_body(async_response, headers_hash)
      body = async_response.body
      return nil unless body

      validate_content_length(headers_hash) unless body.empty?
      read_body_chunks(async_response)
    end

    # Decodes the raw body chunks into the final body string.
    #
    # This method joins the chunks, inflates gzip and deflate content, which enforces
    # `max_response_size` on the inflated bytes, and applies the charset from the
    # Content-Type header. This is CPU-bound work that is intended to run on a
    # completion worker thread.
    #
    # An encoding that the reader does not support leaves the body encoded, and a body
    # that is still encoded keeps its binary encoding, because the charset does not
    # describe it. Use {.split_encodings} to find what stays applied, so that the
    # content-encoding header that is delivered with the response describes the body
    # that it carries.
    #
    # @param chunks [Array<String>, nil] The raw body chunks.
    # @param headers_hash [Hash] The response headers.
    # @return [String, nil] The decoded body, or nil if there is no body.
    # @raise [ResponseTooLargeError] If the inflated body is larger than
    #   `max_response_size`.
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

    # Removes the given encodings from the body, and starts with the encoding that was
    # applied last. The identity encoding needs no work. Every other name here
    # inflates the body.
    #
    # @param chunks [Array<String>] The encoded body chunks.
    # @param encodings [Array<String>] The decodable encoding names, in the order in
    #   which they were applied.
    # @return [Array<String>] The decoded chunks.
    # @raise [ResponseTooLargeError] If the inflated body is larger than
    #   `max_response_size`.
    def inflate_encodings(chunks, encodings)
      encodings.reverse_each do |name|
        chunks = [inflate_encoding(chunks, name)] if INFLATE_WINDOW_BITS.key?(name)
      end

      chunks
    end

    # Inflates one encoding, and tries each wire format that the encoding can use. All
    # the chunks are in memory, so a format that turns out to be wrong can be
    # abandoned and the next one can start at the beginning of the body.
    #
    # @param chunks [Array<String>] The encoded body chunks.
    # @param name [String] A lowercase content encoding name.
    # @return [String] The inflated body.
    # @raise [Zlib::Error] If no format could inflate the body.
    # @raise [ResponseTooLargeError] If the inflated body is larger than
    #   `max_response_size`.
    def inflate_encoding(chunks, name)
      formats = INFLATE_WINDOW_BITS.fetch(name)
      last_index = formats.size - 1

      formats.each_with_index do |window_bits, index|
        return inflate_chunks(chunks, window_bits)
      rescue Zlib::DataError, Zlib::BufError
        raise if index == last_index
      end
    end

    # Reports an encoding that could not be removed. The body is still delivered with
    # its content-encoding header, so the caller can decode it, but the server ignored
    # the accept-encoding header, and that is worth recording.
    #
    # @param remaining [Array<String>] The encodings that are left on the body.
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

    # Validates that the content-length header is not larger than the maximum size.
    #
    # @param headers_hash [Hash] The response headers.
    # @return [void]
    # @raise [ResponseTooLargeError] If the content length is larger than
    #   `max_response_size`.
    def validate_content_length(headers_hash)
      content_length = headers_hash["content-length"]&.to_i
      if content_length && content_length > max_response_size
        raise ResponseTooLargeError.new(
          "Response body size (#{content_length} bytes) exceeds maximum allowed size (#{max_response_size} bytes)"
        )
      end
    end

    # Reads the body chunks and checks their size.
    #
    # @param async_response [Async::HTTP::Protocol::Response] The async HTTP response.
    # @return [Array<String>] The raw body chunks.
    # @raise [ResponseTooLargeError] If the body grows larger than `max_response_size`
    #   during the read.
    # @raise [ReadAbortedError] If the processor stopped past its shutdown deadline
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
        # Always close the body after an interruption or an error, so that the
        # connection returns to the pool.
        async_response.body.close unless finished
      end
    end

    # Inflates the compressed body chunks and enforces the size limit while it
    # streams, so that a small compressed body cannot expand past
    # `max_response_size`.
    #
    # @param chunks [Array<String>] The raw compressed chunks.
    # @param window_bits [Integer] The Zlib window bits for the content encoding.
    # @return [String] The inflated body.
    # @raise [ResponseTooLargeError] If the inflated size is larger than
    #   `max_response_size`.
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

    # Extracts the charset from the Content-Type header.
    #
    # @param headers_hash [Hash] The response headers.
    # @return [String, nil] The charset name, or nil if the header does not name one.
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
    # This method sets the string encoding from the charset that the Content-Type
    # header names. It falls back to ASCII-8BIT if the charset is not valid or not
    # recognized.
    #
    # @param body [String] The response body.
    # @param headers_hash [Hash] The response headers.
    # @return [String] The body, with the encoding set.
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
