# frozen_string_literal: true

module PatientHttp
  # Reads and validates HTTP response bodies.
  #
  # Encapsulates the logic for reading async HTTP responses with size validation
  # and building Response objects from the raw response data.
  class ResponseReader
    # Raised when a body read is aborted because the processor was stopped
    # past its shutdown deadline. The shutdown sequence re-enqueues the task,
    # so this error is handled internally and never reaches callbacks.
    #
    # @api private
    class ReadAbortedError < StandardError; end

    # Initialize the reader.
    #
    # @param processor [Processor] the processor object
    def initialize(processor)
      @processor = processor
    end

    # Read the response body with size validation.
    #
    # Reads the async HTTP response body asynchronously to completion, which allows
    # the connection to be reused. The async-http client handles connection pooling
    # and keep-alive internally. Using iteration instead of read() ensures non-blocking
    # I/O that yields to the reactor.
    #
    # @param async_response [Async::HTTP::Protocol::Response] the async HTTP response
    # @param headers_hash [Hash] the response headers
    # @return [String, nil] the response body or nil if no body present
    # @raise [ResponseTooLargeError] if body exceeds max_response_size
    # @raise [ReadAbortedError] if the processor stopped past its shutdown deadline mid-read
    def read_body(async_response, headers_hash)
      return nil unless async_response.body

      validate_content_length(headers_hash)
      body = read_body_chunks(async_response)
      apply_charset_encoding(body, headers_hash)
    end

    private

    def max_response_size
      @processor.config.max_response_size
    end

    def logger
      @processor.config.logger
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
    # @return [String] the response body in ASCII-8BIT encoding
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
          if @processor.stopped?
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

        # Join chunks and force to binary encoding to preserve raw bytes
        chunks.join.force_encoding(Encoding::ASCII_8BIT)
      ensure
        # Always close the body if we were interrupted or if an error occurred
        # This ensures the connection is properly released back to the pool
        async_response.body.close unless finished
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
