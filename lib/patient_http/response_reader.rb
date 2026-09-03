# frozen_string_literal: true

module PatientHttp
  # Reads and decodes HTTP response bodies.
  #
  # Reading happens on the reactor thread and collects the raw (possibly
  # compressed) body chunks with size validation. Decoding — joining the
  # chunks, inflating compressed content, and applying the charset — is a
  # separate step so it can run on a completion worker thread instead of
  # blocking the event loop.
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
      # Split the encodings named in the content-encoding header into the ones
      # that stay applied to the body and the ones that can be decoded.
      #
      # A body can carry more than one encoding. They are listed in the order
      # they were applied, so decoding runs from the last name backwards and
      # stops at the first name it does not recognize. Everything before that
      # point stays applied to the body.
      #
      # @param headers_hash [Hash] the response headers
      # @return [Array(Array<String>, Array<String>)] the encodings that remain
      #   applied and the encodings that can be decoded, both in applied order
      def split_encodings(headers_hash)
        encodings = content_encodings(headers_hash)
        boundary = encodings.rindex { |name| !decodable?(name) }
        return [[], encodings] if boundary.nil?

        [encodings[0..boundary], encodings[(boundary + 1)..]]
      end

      # Parse the content-encoding header into encoding names.
      #
      # @param headers_hash [Hash] the response headers
      # @return [Array<String>] the lowercased encoding names in applied order
      def content_encodings(headers_hash)
        headers_hash["content-encoding"].to_s.split(",").filter_map do |name|
          name = name.strip.downcase
          name unless name.empty?
        end
      end

      # @param name [String] a lowercased content encoding name
      # @return [Boolean] true if the reader can remove this encoding
      def decodable?(name)
        name == IDENTITY_ENCODING || INFLATE_WINDOW_BITS.key?(name)
      end

      # Restate the content-encoding header for a decoded body. The header is
      # removed when nothing is left applied, and narrowed to the encodings the
      # reader could not remove otherwise, so the header always describes the
      # body delivered with it.
      #
      # @param headers_hash [Hash] the response headers
      # @return [Hash] the headers with content-encoding updated or removed
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

    # Initialize the reader.
    #
    # Reading needs a processor so it can abort once the processor is past its
    # shutdown deadline. Decoding needs only the configuration, so a caller
    # that does its own reading can supply the configuration on its own.
    #
    # @param processor [Processor, nil] the processor object
    # @param config [Configuration, nil] the configuration; defaults to the
    #   processor's configuration
    def initialize(processor, config: nil)
      @processor = processor
      @config = config || processor.config
    end

    # Read the raw response body chunks with size validation.
    #
    # Reads the async HTTP response body asynchronously to completion, which allows
    # the connection to be reused. The async-http client handles connection pooling
    # and keep-alive internally. Using iteration instead of read() ensures non-blocking
    # I/O that yields to the reactor. The chunks are the wire bytes: when the
    # response is compressed, the size check here applies to the compressed
    # bytes and {#decode_body} applies the same limit to the inflated bytes.
    #
    # The Content-Length header is checked against the size limit before the
    # read starts. A response to a HEAD request has an empty body but reports
    # the Content-Length of the resource, so the header check is skipped when
    # the body reports itself as empty.
    #
    # @param async_response [Async::HTTP::Protocol::Response] the async HTTP response
    # @param headers_hash [Hash] the response headers
    # @return [Array<String>, nil] the raw body chunks or nil if no body present
    # @raise [ResponseTooLargeError] if the body exceeds max_response_size
    # @raise [ReadAbortedError] if the processor stopped past its shutdown deadline mid-read
    def read_raw_body(async_response, headers_hash)
      body = async_response.body
      return nil unless body

      validate_content_length(headers_hash) unless body.empty?
      read_body_chunks(async_response)
    end

    # Decode raw body chunks into the final body string.
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
    # @param chunks [Array<String>, nil] the raw body chunks
    # @param headers_hash [Hash] the response headers
    # @return [String, nil] the decoded body or nil if there was no body
    # @raise [ResponseTooLargeError] if the inflated body exceeds max_response_size
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

    # Remove the given encodings from the body, starting with the one applied
    # last. Identity needs no work; every other name here inflates.
    #
    # @param chunks [Array<String>] the encoded body chunks
    # @param encodings [Array<String>] decodable encoding names in applied order
    # @return [Array<String>] the decoded chunks
    # @raise [ResponseTooLargeError] if the inflated body exceeds max_response_size
    def inflate_encodings(chunks, encodings)
      encodings.reverse_each do |name|
        chunks = [inflate_encoding(chunks, name)] if INFLATE_WINDOW_BITS.key?(name)
      end

      chunks
    end

    # Inflate one encoding, trying each wire format the encoding can use. The
    # chunks are all in memory, so a format that turns out to be wrong can be
    # abandoned and the next one started from the beginning of the body.
    #
    # @param chunks [Array<String>] the encoded body chunks
    # @param name [String] a lowercased content encoding name
    # @return [String] the inflated body
    # @raise [Zlib::Error] if no format could inflate the body
    # @raise [ResponseTooLargeError] if the inflated body exceeds max_response_size
    def inflate_encoding(chunks, name)
      formats = INFLATE_WINDOW_BITS.fetch(name)
      last_index = formats.size - 1

      formats.each_with_index do |window_bits, index|
        return inflate_chunks(chunks, window_bits)
      rescue Zlib::DataError, Zlib::BufError
        raise if index == last_index
      end
    end

    # Report an encoding that could not be removed. The body is still delivered
    # with its content-encoding header, so the caller can decode it, but the
    # server ignored the accept-encoding header and that is worth recording.
    #
    # @param remaining [Array<String>] the encodings left on the body
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

    # Validate content-length header doesn't exceed max size.
    #
    # @param headers_hash [Hash] the response headers
    # @raise [ResponseTooLargeError] if content-length exceeds max_response_size
    def validate_content_length(headers_hash)
      content_length = headers_hash["content-length"]&.to_i
      if content_length && content_length > max_response_size
        raise ResponseTooLargeError.new(
          "Response body size (#{content_length} bytes) exceeds maximum allowed size (#{max_response_size} bytes)"
        )
      end
    end

    # Read body chunks while checking size.
    #
    # @param async_response [Async::HTTP::Protocol::Response] the async HTTP response
    # @return [Array<String>] the raw body chunks
    # @raise [ResponseTooLargeError] if body size exceeds max_response_size during read
    # @raise [ReadAbortedError] if the processor stopped past its shutdown deadline mid-read
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

    # Inflate compressed body chunks with streaming size enforcement, so a
    # small compressed body cannot expand past max_response_size.
    #
    # @param chunks [Array<String>] the raw compressed chunks
    # @param window_bits [Integer] Zlib window bits for the content encoding
    # @return [String] the inflated body
    # @raise [ResponseTooLargeError] if the inflated size exceeds max_response_size
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

    # Extract charset from Content-Type header.
    #
    # @param headers_hash [Hash] the response headers
    # @return [String, nil] the charset name or nil if not specified
    def extract_charset(headers_hash)
      content_type = headers_hash["content-type"]
      return nil unless content_type

      match = content_type.match(/;\s*charset\s*=\s*([^;\s]+)/i)
      return nil unless match

      charset = match[1].strip
      charset.gsub(/\A["']|["']\z/, "")
    end

    # Apply charset encoding to response body.
    #
    # Sets the string encoding based on the charset specified in the Content-Type header.
    # Falls back to ASCII-8BIT if charset is invalid or not recognized.
    #
    # @param body [String] the response body
    # @param headers_hash [Hash] the response headers
    # @return [String] the body with proper encoding set
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
