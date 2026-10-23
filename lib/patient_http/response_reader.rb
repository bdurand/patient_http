# frozen_string_literal: true

module PatientHttp
  # Reads and decodes HTTP response bodies.
  #
  # The reactor thread reads the raw body chunks, which can be compressed, and
  # checks their size. Decoding is a separate step that runs on a completion
  # worker thread, so it doesn't block the reactor. Decoding joins the chunks,
  # decompresses them, and applies the charset.
  #
  # @api private
  class ResponseReader
    # Raised when a body read is aborted because the processor was stopped
    # past its shutdown deadline. The shutdown sequence re-enqueues the task,
    # so this error is handled internally and never reaches callbacks.
    #
    # @api private
    class ReadAbortedError < StandardError; end

    # Content encodings that are inflated during decoding, mapped to the window
    # bits of each wire format the encoding may arrive in. Formats are tried in
    # order until one inflates the body.
    #
    # A "deflate" body should carry a zlib header (RFC 9110 specifies the zlib
    # format), but some servers send a bare deflate stream instead, so the raw
    # format is kept as a fallback.
    INFLATE_WINDOW_BITS = {
      "gzip" => [Zlib::MAX_WBITS | 16].freeze,
      "deflate" => [Zlib::MAX_WBITS, -Zlib::MAX_WBITS].freeze
    }.freeze

    # Content encoding that means the body was not encoded at all. It needs no
    # work to decode, but it still has to be recognized so it does not stop the
    # decode of the encodings applied before it.
    IDENTITY_ENCODING = "identity"

    class << self
      # Splits the encodings named in the content-encoding header into the ones
      # that stay applied to the body and the ones that can be decoded.
      #
      # A body can carry more than one encoding. They are listed in the order
      # they were applied, so decoding runs from the last name backwards and
      # stops at the first name it does not recognize. Everything before that
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

      # Parses the content-encoding header into encoding names.
      #
      # @param headers_hash [Hash] The response headers.
      # @return [Array<String>] The lowercased encoding names in applied order.
      def content_encodings(headers_hash)
        headers_hash["content-encoding"].to_s.split(",").filter_map do |name|
          name = name.strip.downcase
          name unless name.empty?
        end
      end

      # @param name [String] A lowercased content encoding name.
      # @return [Boolean] `true` if the reader can remove this encoding.
      def decodable?(name)
        name == IDENTITY_ENCODING || INFLATE_WINDOW_BITS.key?(name)
      end

      # Restates the content-encoding header for a decoded body. The header is
      # removed when nothing is left applied, and narrowed to the encodings the
      # reader could not remove otherwise, so the header always describes the
      # body delivered with it.
      #
      # @param headers_hash [Hash] The response headers.
      # @return [Hash] The headers with content-encoding updated or removed.
      def rewrite_content_encoding(headers_hash)
        return headers_hash unless headers_hash.key?("content-encoding")

        remaining, _decodable = split_encodings(headers_hash)

        if remaining.empty?
          headers_hash.except("content-encoding")
        else
          headers_hash.merge("content-encoding" => remaining.join(", "))
        end
      end

      # Runs a block that waits for data from the server, and stops it if no
      # data arrives in time. Each call starts a new timer, so call it once for
      # each wait: once for the response headers and once for each body chunk.
      #
      # The block must run in an Async task.
      #
      # @param read_timeout [Numeric, nil] The maximum number of seconds to wait.
      #   If `nil`, the block runs without a limit.
      # @yield Waits for data from the server.
      # @return [Object] The value of the block.
      # @raise [ReadTimeoutError] If the block doesn't finish in time.
      def with_read_timeout(read_timeout, &block)
        return yield if read_timeout.nil?

        Async::Task.current.with_timeout(
          read_timeout,
          ReadTimeoutError,
          "No data received from the server for #{read_timeout} seconds",
          &block
        )
      end
    end

    # Creates the reader.
    #
    # Reading needs a processor so it can abort once the processor is past its
    # shutdown deadline. Decoding needs only the configuration, so a caller
    # that does its own reading can supply the configuration on its own.
    #
    # @param processor [Processor, nil] The processor object.
    # @param config [Configuration, nil] The configuration; defaults to the
    #   processor's configuration.
    def initialize(processor, config: nil)
      @processor = processor
      @config = config || processor.config
    end

    # Reads the raw response body chunks with size validation.
    #
    # Reads the async HTTP response body asynchronously to completion, which allows
    # the connection to be reused. The async-http client handles connection pooling
    # and keep-alive internally. Using iteration instead of read() ensures non-blocking
    # I/O that yields to the reactor. The chunks are the wire bytes: when the
    # response is compressed, the size check here applies to the compressed
    # bytes and {#decode_body} applies the same limit to the inflated bytes.
    #
    # The Content-Length header is checked against the size limit before the
    # read starts. The HTTP/1 parser moves that header into the body, so the
    # length of the body is used when the header is not present. A response to
    # a HEAD request has an empty body but reports the Content-Length of the
    # resource, so the check is skipped when the body reports itself as empty.
    #
    # A read timeout limits the wait for each chunk. The timer starts again
    # each time a chunk arrives, so a body that arrives slowly but steadily is
    # read to the end.
    #
    # @param async_response [Async::HTTP::Protocol::Response] The async HTTP response.
    # @param headers_hash [Hash] The response headers.
    # @param max_response_size [Integer, nil] The size limit in bytes. If `nil`,
    #   the configuration value applies.
    # @param read_timeout [Numeric, nil] The maximum number of seconds to wait for
    #   each chunk. If `nil`, there is no limit.
    # @return [Array<String>, nil] The raw body chunks or nil if no body present.
    # @raise [ResponseTooLargeError] If the body exceeds max_response_size.
    # @raise [ReadTimeoutError] If no chunk arrives within the read timeout.
    # @raise [ReadAbortedError] If the processor stopped past its shutdown deadline mid-read.
    def read_raw_body(async_response, headers_hash, max_response_size: nil, read_timeout: nil)
      body = async_response.body
      return nil unless body

      limit = max_response_size || @config.max_response_size
      error = nil

      begin
        validate_content_length(headers_hash, body, limit) unless body.empty?
        read_body_chunks(body, limit, read_timeout)
      rescue => e
        error = e
        raise
      ensure
        # Always close the body. A body that is closed with an error discards
        # its connection, so a connection that is not fully read is not
        # returned to the pool.
        body.close(error)
      end
    end

    # Decodes raw body chunks into the final body string.
    #
    # Joins the chunks, inflates gzip/deflate content (enforcing
    # max_response_size on the inflated bytes), and applies the charset from
    # the Content-Type header. This is CPU-bound work intended to run on a
    # completion worker thread.
    #
    # An encoding the reader does not support leaves the body encoded, and a
    # body that is still encoded keeps its binary encoding because the charset
    # does not describe it. Use {.split_encodings} to find what stays applied
    # so the content-encoding header delivered with the response describes the
    # body it carries.
    #
    # @param chunks [Array<String>, nil] The raw body chunks.
    # @param headers_hash [Hash] The response headers.
    # @param max_response_size [Integer, nil] The size limit in bytes for the
    #   inflated body. If `nil`, the configuration value applies.
    # @return [String, nil] The decoded body or nil if there was no body.
    # @raise [ResponseTooLargeError] If the inflated body exceeds max_response_size.
    def decode_body(chunks, headers_hash, max_response_size: nil)
      return nil if chunks.nil?

      remaining, decodable = self.class.split_encodings(headers_hash)
      warn_undecodable(remaining) unless remaining.empty?

      limit = max_response_size || @config.max_response_size
      body = inflate_encodings(chunks, decodable, limit).join
      body.force_encoding(Encoding::ASCII_8BIT)
      # A body that is still encoded is not text yet, so the charset does not
      # describe its bytes. Leave it binary for the caller to decode.
      return body unless remaining.empty?

      apply_charset_encoding(body, headers_hash)
    end

    private

    # Removes the given encodings from the body, starting with the one applied
    # last. Identity needs no work; every other name here inflates.
    #
    # @param chunks [Array<String>] The encoded body chunks.
    # @param encodings [Array<String>] Decodable encoding names in applied order.
    # @param limit [Integer] The size limit in bytes for the inflated body.
    # @return [Array<String>] The decoded chunks.
    # @raise [ResponseTooLargeError] If the inflated body exceeds the limit.
    def inflate_encodings(chunks, encodings, limit)
      encodings.reverse_each do |name|
        chunks = [inflate_encoding(chunks, name, limit)] if INFLATE_WINDOW_BITS.key?(name)
      end

      chunks
    end

    # Inflates one encoding, trying each wire format the encoding can use. The
    # chunks are all in memory, so a format that turns out to be wrong can be
    # abandoned and the next one started from the beginning of the body.
    #
    # @param chunks [Array<String>] The encoded body chunks.
    # @param name [String] A lowercased content encoding name.
    # @param limit [Integer] The size limit in bytes for the inflated body.
    # @return [String] The inflated body.
    # @raise [Zlib::Error] If no format could inflate the body.
    # @raise [ResponseTooLargeError] If the inflated body exceeds the limit.
    def inflate_encoding(chunks, name, limit)
      formats = INFLATE_WINDOW_BITS.fetch(name)
      last_index = formats.size - 1

      formats.each_with_index do |window_bits, index|
        return inflate_chunks(chunks, window_bits, limit)
      rescue Zlib::DataError, Zlib::BufError
        raise if index == last_index
      end
    end

    # Reports an encoding that could not be removed. The body is still delivered
    # with its content-encoding header, so the caller can decode it, but the
    # server ignored the accept-encoding header and that is worth recording.
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

    def logger
      @config.logger
    end

    # Validates the declared body length doesn't exceed max size.
    #
    # @param headers_hash [Hash] The response headers.
    # @param body [Protocol::HTTP::Body::Readable] The response body.
    # @param limit [Integer] The size limit in bytes.
    # @raise [ResponseTooLargeError] If the declared length exceeds the limit.
    def validate_content_length(headers_hash, body, limit)
      content_length = headers_hash["content-length"]&.to_i || body.length
      if content_length && content_length > limit
        raise ResponseTooLargeError.new(
          "Response body size (#{content_length} bytes) exceeds maximum allowed size (#{limit} bytes)"
        )
      end
    end

    # Reads body chunks while checking size.
    #
    # Each chunk is read with its own read timeout, so the timer starts again
    # after every chunk.
    #
    # @param body [Protocol::HTTP::Body::Readable] The response body.
    # @param limit [Integer] The size limit in bytes.
    # @param read_timeout [Numeric, nil] The maximum number of seconds to wait for
    #   each chunk.
    # @return [Array<String>] The raw body chunks.
    # @raise [ResponseTooLargeError] If body size exceeds the limit during read.
    # @raise [ReadTimeoutError] If no chunk arrives within the read timeout.
    # @raise [ReadAbortedError] If the processor stopped past its shutdown deadline mid-read.
    def read_body_chunks(body, limit, read_timeout)
      chunks = []
      total_size = 0

      while (chunk = self.class.with_read_timeout(read_timeout) { body.read })
        # Abort the read once the processor has passed its shutdown deadline.
        # Reads are allowed to finish while the processor is merely stopping
        # (the graceful shutdown window) so in-flight responses can still be
        # delivered.
        if @processor&.stopped?
          raise ReadAbortedError.new("Processor stopped while reading response body")
        end

        total_size += chunk.bytesize

        if total_size > limit
          raise ResponseTooLargeError.new(
            "Response body size exceeded maximum allowed size (#{limit} bytes)"
          )
        end

        chunks << chunk
      end

      chunks
    end

    # Inflates compressed body chunks with streaming size enforcement, so a
    # small compressed body cannot expand past the size limit.
    #
    # @param chunks [Array<String>] The raw compressed chunks.
    # @param window_bits [Integer] Zlib window bits for the content encoding.
    # @param limit [Integer] The size limit in bytes for the inflated body.
    # @return [String] The inflated body.
    # @raise [ResponseTooLargeError] If the inflated size exceeds the limit.
    def inflate_chunks(chunks, window_bits, limit)
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
          validate_inflated_size(body, limit)
        end

        chunks.each { |chunk| inflater.inflate(chunk, &appender) }
        inflater.finish(&appender) unless inflater.finished?
      ensure
        inflater.close
      end

      body
    end

    def validate_inflated_size(body, limit)
      if body.bytesize > limit
        raise ResponseTooLargeError.new(
          "Response body size exceeded maximum allowed size (#{limit} bytes)"
        )
      end
    end

    # Extracts charset from Content-Type header.
    #
    # @param headers_hash [Hash] The response headers.
    # @return [String, nil] The charset name or nil if not specified.
    def extract_charset(headers_hash)
      content_type = headers_hash["content-type"]
      return nil unless content_type

      match = content_type.match(/;\s*charset\s*=\s*([^;\s]+)/i)
      return nil unless match

      charset = match[1].strip
      charset.gsub(/\A["']|["']\z/, "")
    end

    # Applies charset encoding to response body.
    #
    # Sets the string encoding based on the charset specified in the Content-Type header.
    # Falls back to ASCII-8BIT if charset is invalid or not recognized.
    #
    # @param body [String] The response body.
    # @param headers_hash [Hash] The response headers.
    # @return [String] The body with proper encoding set.
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
