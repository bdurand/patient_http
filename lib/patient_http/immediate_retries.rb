# frozen_string_literal: true

module PatientHttp
  # Retries a request at once when its failure is known to be safe to retry.
  #
  # Only failures raised before any response byte arrives are considered; a
  # failure while reading the body is never retried. The pooled clients make a
  # single attempt per call, so this module is the only layer that retries and
  # one limit bounds how many times a request is sent.
  #
  # A connection failure evicts the host's pooled client before the retry, so
  # the retry opens a new connection instead of taking another idle connection
  # that may have failed the same way. Each attempt looks up the host's client
  # in the pool, so a retry never runs on a client a concurrent failure evicted.
  #
  # The including class must provide a private `config` method returning the
  # {Configuration}, which supplies the logger.
  #
  # @api private
  module ImmediateRetries
    # Minimum number of attempts made after a failure that is safe to retry. A
    # pool `retries` setting above IMMEDIATE_RETRY_LIMIT + 1 allows
    # `retries - 1` attempts instead.
    IMMEDIATE_RETRY_LIMIT = 2

    # Errors from a connection that failed before delivering any response byte.
    # They are ambiguous for a non-idempotent request: the server may have
    # processed it and then died, or it may never have received it. IOError
    # covers EOFError and the IO::TimeoutError raised by the connection timeout.
    # EPIPE means a write failed, but the server may already have read enough of
    # the request to act on it before closing. ETIMEDOUT is the kernel giving up
    # on unacknowledged data (see the TCP user timeout), not the request
    # timeout, which is never retried.
    CONNECTION_ERRORS = [
      IOError, SocketError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE, Errno::ETIMEDOUT,
      ::Protocol::HTTP::RemoteError
    ].freeze

    private

    # Send the request through the pool, retrying safe failures at once.
    #
    # @param client_pool [ClientPool] the pool to send through
    # @param request [Request] the request being sent, used for its method and URL
    # @param endpoint [Async::HTTP::Endpoint] the endpoint parsed from the prepared URL
    # @param headers [Hash] the prepared request headers
    # @param body [Protocol::HTTP::Body::Buffered, nil] the request body
    # @yield [client] each pooled client before a request is sent through it
    # @return [Protocol::HTTP::Response] the response with its headers read
    def request_with_immediate_retries(client_pool, request, endpoint, headers, body)
      limit = [client_pool.retries - 1, IMMEDIATE_RETRY_LIMIT].max
      attempt = 1

      loop do
        client = client_pool.client_for(endpoint)
        yield client if block_given?
        return client_pool.request(request.http_method, endpoint, headers, body, client: client)
      rescue => e
        unless attempt <= limit && immediately_retryable?(request, e)
          raise
        end

        if client && connection_failure?(e)
          client_pool.evict(endpoint.url.to_s, client)
        end

        attempt += 1
        body&.rewind
        # The request URL is logged rather than the prepared URL, which carries
        # resolved secret params.
        config.logger&.info(
          "[PatientHttp] Request to #{request.url} failed before a response " \
          "(#{e.class.name}: #{e.message}); retrying (attempt #{attempt})"
        )
      end
    end

    # A refused request (an HTTP/2 GOAWAY, a pooled connection closed after it was
    # acquired, or a rejected stream) was never processed by the server, so it is
    # safe to retry whatever the method. A connection that fails in any other way
    # before responding may have processed the request, so that failure is
    # retried only for idempotent methods.
    def immediately_retryable?(request, error)
      case error
      when ::Protocol::HTTP::RefusedError
        true
      when *CONNECTION_ERRORS
        request.idempotent?
      else
        false
      end
    end

    def connection_failure?(error)
      CONNECTION_ERRORS.any? { |error_class| error.is_a?(error_class) }
    end
  end
end
