# frozen_string_literal: true

module PatientHttp
  class Client
    # Attempts made after a failure that is safe to retry at once, such as the
    # server refusing a request before processing it.
    IMMEDIATE_RETRY_LIMIT = 2

    # Errors from a connection that failed before delivering any response byte.
    # They are ambiguous for a non-idempotent request: the server may have
    # processed it and then died, or it may never have received it. ETIMEDOUT is
    # the kernel giving up on unacknowledged data (see the TCP user timeout), not
    # the request timeout, which is never retried.
    STALE_CONNECTION_ERRORS = [
      EOFError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::ETIMEDOUT
    ].freeze

    def initialize(processor)
      @processor = processor
      @client_pool = ClientPool.new(
        max_size: config.connection_pool_size,
        connection_timeout: config.connection_timeout,
        proxy_url: config.proxy_url,
        retries: config.retries,
        protocol: config.protocol,
        connection_limit: config.max_connections_per_host,
        tcp_keepalive: config.tcp_keepalive,
        tcp_user_timeout: config.tcp_user_timeout
      )
      @response_reader = ResponseReader.new(@processor)
      @request_preparer = RequestPreparer.new(config)
    end

    # Make an asynchronous HTTP request.
    #
    # The returned body is the array of raw (possibly compressed) body chunks;
    # use {#decode_response} to produce the final body string. Splitting the
    # decode out keeps CPU-bound work off the reactor thread.
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
          async_response = request_with_immediate_retries(request, url, headers, body)
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
        # Close the response and evict the client for this host to ensure the
        # stale connection is not reused for subsequent requests.
        async_response&.close
        if connection_error?(e)
          @client_pool.evict(request.url)
        end
        raise
      end
    end

    # Decode raw response data into deliverable response data.
    #
    # Joins and inflates the raw body chunks, applies the charset, and rewrites
    # the content-encoding header to name only the encodings still applied to
    # the body. The header is removed when nothing is left, and kept when the
    # server used an encoding the reader cannot decode, so the delivered
    # response always describes the body it carries. This is CPU-bound work
    # intended to run on a completion worker thread.
    #
    # @param response_data [Hash] raw response data from {#make_request}
    # @return [Hash] response data with the decoded body string
    # @raise [ResponseTooLargeError] if the inflated body exceeds max_response_size
    def decode_response(response_data)
      headers = response_data[:headers]
      body = @response_reader.decode_body(response_data[:body], headers)
      headers = ResponseReader.rewrite_content_encoding(headers)

      response_data.merge(headers: headers, body: body)
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

    # Send the request, retrying at once when a failure is known to be safe to
    # retry. Only failures raised before any response byte arrives reach this
    # method; a failure while reading the body is never retried. The pool retires
    # a connection that failed when it is released, so a retry opens a new one.
    def request_with_immediate_retries(request, url, headers, body)
      attempt = 1

      loop do
        return @client_pool.request(request.http_method, url, headers, body)
      rescue => e
        raise unless attempt <= IMMEDIATE_RETRY_LIMIT && immediately_retryable?(request, e)

        attempt += 1
        body&.rewind
        config.logger&.info(
          "[PatientHttp] Request to #{url} failed before a response (#{e.class.name}: #{e.message}); " \
          "retrying on a new connection (attempt #{attempt})"
        )
      end
    end

    # A refused request (an HTTP/2 GOAWAY, a pooled connection closed after it was
    # acquired, or a rejected stream) was never processed by the server. EPIPE is
    # raised while writing, so the server did not receive the whole request. Both
    # are safe to retry whatever the method. A connection that fails in any other
    # way before responding may have processed the request, so that failure is
    # retried only for idempotent methods.
    def immediately_retryable?(request, error)
      case error
      when ::Protocol::HTTP::RefusedError, Errno::EPIPE
        true
      when *STALE_CONNECTION_ERRORS
        request.idempotent?
      else
        false
      end
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
