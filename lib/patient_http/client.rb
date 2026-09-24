# frozen_string_literal: true

module PatientHttp
  # Sends HTTP requests for a {Processor} through a pool of HTTP clients.
  #
  # @api private
  class Client
    include ImmediateRetries

    # Creates a client for a processor.
    #
    # @param processor [Processor] The processor that owns the client.
    def initialize(processor)
      @processor = processor
      @client_pool = ClientPool.from_config(config)
      @response_reader = ResponseReader.new(@processor)
      @request_preparer = RequestPreparer.new(config)
    end

    # Makes an asynchronous HTTP request.
    #
    # The returned body is an array of raw body chunks, which might be compressed.
    # Use {#decode_response} to produce the final body string. Decoding in a
    # separate step keeps CPU-bound work off the reactor thread.
    #
    # @param request [Request] The request to make.
    # @param request_id [String] A unique request identifier.
    # @return [Hash] The response data with the keys `:status`, `:headers`, and `:body`.
    def make_request(request, request_id)
      async_response = nil
      client = nil

      begin
        outgoing = @request_preparer.prepare(request, request_id)
        url = outgoing.url
        headers = outgoing.headers.to_h
        body = Protocol::HTTP::Body::Buffered.wrap([request.body.to_s]) if request.body
        timeout = request.timeout || config.request_timeout

        Async::Task.current.with_timeout(timeout) do
          endpoint = Async::HTTP::Endpoint.parse(url)
          async_response = request_with_immediate_retries(
            @client_pool, request, endpoint, headers, body
          ) { |pooled_client| client = pooled_client }
          # Note: headers that appear multiple times (e.g. set-cookie) are
          # flattened to a single joined string value.
          headers_hash = async_response.headers.to_h.transform_values(&:to_s)
          body = @response_reader.read_raw_body(async_response, headers_hash)

          {
            status: async_response.status,
            headers: headers_hash,
            body: body
          }
        end
      rescue => e
        # Close the response and evict the client that failed so its stale
        # connections are not reused. Evicting by identity leaves a replacement
        # client for the host alone.
        async_response&.close
        if client && connection_error?(e)
          @client_pool.evict(url, client)
        end
        raise
      end
    end

    # Decodes raw response data into response data that is ready to deliver.
    #
    # This method joins and inflates the raw body chunks, applies the charset, and
    # rewrites the `content-encoding` header to name only the encodings still
    # applied to the body. If no encodings remain, the header is removed. If the
    # server used an encoding that the reader can't decode, the header is kept.
    # The delivered response always describes the body it carries. This work is
    # CPU-bound and runs on a completion worker thread.
    #
    # @param response_data [Hash] The raw response data from {#make_request}.
    # @return [Hash] The response data with the decoded body string.
    # @raise [ResponseTooLargeError] If the inflated body exceeds `max_response_size`.
    def decode_response(response_data)
      headers = response_data[:headers]
      body = @response_reader.decode_body(response_data[:body], headers)
      headers = ResponseReader.rewrite_content_encoding(headers)

      response_data.merge(headers: headers, body: body)
    end

    # Closes all clients and releases their resources.
    #
    # @return [void]
    def close
      @client_pool.close
    end

    private

    def config
      @processor.config
    end

    def connection_error?(exception)
      case exception
      when Async::TimeoutError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE,
           Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, SocketError, IOError
        true
      else
        false
      end
    end
  end
end
