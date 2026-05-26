# frozen_string_literal: true

module PatientHttp
  class Client
    def initialize(processor)
      @processor = processor
      @client_pool = ClientPool.new(
        max_size: config.connection_pool_size,
        connection_timeout: config.connection_timeout,
        proxy_url: config.proxy_url,
        retries: config.retries
      )
      @response_reader = ResponseReader.new(@processor)
    end

    # Make an asynchronous HTTP request.
    #
    # @param request [Request] the request to make
    # @param request_id [String] unique request identifier
    # @return [Hash] the response data with keys for :status, :headers, and :body
    def make_request(request, request_id)
      async_response = nil

      begin
        headers = request_headers(request, request_id)
        body = Protocol::HTTP::Body::Buffered.wrap([request.body.to_s]) if request.body
        timeout = request.timeout || config.request_timeout

        Async::Task.current.with_timeout(timeout) do
          async_response = @client_pool.request(request.http_method, request.url, headers, body)
          headers_hash = async_response.headers.to_h.transform_values(&:to_s)
          body = @response_reader.read_body(async_response, headers_hash)

          {
            status: async_response.status,
            headers: headers_hash,
            body: body
          }
        end
      rescue
        # Close the response on timeout or error to discard the connection
        # rather than returning it to the pool in a dirty state.
        async_response&.close
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

    def request_headers(request, request_id)
      headers = request.headers.to_h.merge("x-request-id" => request_id)
      headers["user-agent"] ||= config.user_agent if config.user_agent
      headers
    end
  end
end
