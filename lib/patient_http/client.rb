# frozen_string_literal: true

module PatientHttp
  class Client
    def initialize(processor)
      @processor = processor
      @client_pool = ClientPool.new(
        max_size: config.connection_pool_size,
        connection_timeout: config.connection_timeout,
        proxy_url: config.proxy_url,
        retries: config.retries,
        protocol: config.protocol
      )
      @response_reader = ResponseReader.new(@processor)
      @request_preparer = RequestPreparer.new(config)
    end

    # Make an asynchronous HTTP request.
    #
    # @param request [Request] the request to make
    # @param request_id [String] unique request identifier
    # @return [Hash] the response data with keys for :status, :headers, and :body
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
          # Note: headers that appear multiple times (e.g. set-cookie) are
          # flattened to a single joined string value.
          headers_hash = async_response.headers.to_h.transform_values(&:to_s)
          body = @response_reader.read_body(async_response, headers_hash)

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

    # Close all clients and release resources.
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
