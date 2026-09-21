# frozen_string_literal: true

module PatientHttp
  # Sends HTTP requests for a {Processor} through a pool of async HTTP clients.
  #
  # Requests are made on the reactor thread, and the CPU-bound work of decoding a
  # response body is kept separate so that it can run on a completion worker thread.
  #
  # @api private
  class Client
    # Initializes a new Client.
    #
    # @param processor [Processor] The processor that owns this client.
    def initialize(processor)
      @processor = processor
      @client_pool = ClientPool.new(
        max_size: config.connection_pool_size,
        connection_timeout: config.connection_timeout,
        proxy_url: config.proxy_url,
        retries: config.retries,
        protocol: config.protocol,
        connection_limit: config.max_connections_per_host
      )
      @response_reader = ResponseReader.new(@processor)
      @request_preparer = RequestPreparer.new(config)
    end

    # Makes an asynchronous HTTP request.
    #
    # The returned body is an array of raw, possibly compressed, body chunks. Use
    # {#decode_response} to produce the final body string. Decoding separately keeps
    # CPU-bound work off the reactor thread.
    #
    # @param request [Request] The request to make.
    # @param request_id [String] The unique request identifier.
    # @return [Hash] The response data, with the keys `:status`, `:headers`, and
    #   `:body`.
    def make_request(request, request_id)
      async_response = nil

      begin
        outgoing = @request_preparer.prepare(request, request_id)
        url = outgoing.url
        headers = outgoing.headers.to_h
        body = Protocol::HTTP::Body::Buffered.wrap([request.body.to_s]) if request.body
        timeout = request.timeout || config.request_timeout

        Async::Task.current.with_timeout(timeout) do
          async_response = @client_pool.request(request.http_method, url, headers, body)
          # A header that appears more than once, such as set-cookie, is joined
          # into a single string value.
          headers_hash = async_response.headers.to_h.transform_values(&:to_s)
          body = @response_reader.read_raw_body(async_response, headers_hash)

          {
            status: async_response.status,
            headers: headers_hash,
            body: body
          }
        end
      rescue => e
        # Close the response and evict the client for this host to ensure the
        # stale connection is not reused for subsequent requests.
        async_response&.close
        if connection_error?(e)
          @client_pool.evict(request.url)
        end
        raise
      end
    end

    # Decodes raw response data into deliverable response data.
    #
    # This method joins and inflates the raw body chunks, applies the charset, and
    # rewrites the content-encoding header to name only the encodings that are still
    # applied to the body. The header is removed when nothing is left, and it is kept
    # when the server used an encoding that the reader cannot decode, so the delivered
    # response always describes the body it carries. This is CPU-bound work that is
    # intended to run on a completion worker thread.
    #
    # @param response_data [Hash] The raw response data from {#make_request}.
    # @return [Hash] The response data, with the decoded body string.
    # @raise [ResponseTooLargeError] If the inflated body is larger than
    #   `max_response_size`.
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
