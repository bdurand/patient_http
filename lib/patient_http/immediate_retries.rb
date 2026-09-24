# frozen_string_literal: true

module PatientHttp
  # Retries a request immediately when its failure is known to be safe to retry.
  #
  # Only failures raised before any response bytes arrive are retried. A failure
  # while reading the body is never retried. The pooled clients make one attempt
  # per call, so this module is the only layer that retries, and one limit bounds
  # how many times a request is sent.
  #
  # A connection failure evicts the host's pooled client before the retry. The
  # retry then opens a new connection instead of taking another idle connection
  # that might have failed the same way. Each attempt looks up the host's client
  # in the pool, so a retry never runs on a client that a concurrent failure
  # evicted.
  #
  # The including class must provide a private `config` method that returns the
  # {Configuration}, which supplies the logger.
  #
  # @api private
  module ImmediateRetries
    # The minimum number of retries after a failure that is safe to retry. A pool
    # `retries` setting above `IMMEDIATE_RETRY_LIMIT + 1` allows `retries - 1`
    # retries instead.
    IMMEDIATE_RETRY_LIMIT = 2

    # Errors from a connection that failed before it delivered any response bytes.
    # For a non-idempotent request, the outcome is unknown. The server might have
    # processed the request and then failed, or it might never have received it.
    #
    # `IOError` covers `EOFError` and the `IO::TimeoutError` that the connection
    # timeout raises. `EPIPE` means a write failed, but the server might have read
    # enough of the request to act on it before it closed the connection.
    # `ETIMEDOUT` means the kernel gave up on unacknowledged data (see the TCP user
    # timeout). It doesn't mean the request timeout, which is never retried.
    CONNECTION_ERRORS = [
      IOError, SocketError, Errno::ECONNRESET, Errno::ECONNABORTED, Errno::EPIPE, Errno::ETIMEDOUT,
      ::Protocol::HTTP::RemoteError
    ].freeze

    private

    # Sends the request through the pool and retries safe failures immediately.
    #
    # @param client_pool [ClientPool] The pool to send the request through.
    # @param request [Request] The request to send. Its method and URL are used.
    # @param endpoint [Async::HTTP::Endpoint] The endpoint parsed from the prepared URL.
    # @param headers [Hash] The prepared request headers.
    # @param body [Protocol::HTTP::Body::Buffered, nil] The request body.
    # @yield [client] Each pooled client, before the request is sent through it.
    # @return [Protocol::HTTP::Response] The response with its headers read.
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

    # The server never processed a refused request, so it's safe to retry with any
    # method. A request is refused by an HTTP/2 GOAWAY, a rejected stream, or a
    # pooled connection that closed after it was acquired. If a connection fails in
    # any other way before it responds, the server might have processed the
    # request, so the failure is retried only for idempotent methods.
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
