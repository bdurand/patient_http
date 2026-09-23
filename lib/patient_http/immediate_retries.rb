# frozen_string_literal: true

module PatientHttp
  # Retries a request at once when its failure is known to be safe to retry.
  #
  # Only failures raised before any response byte arrives are considered; a
  # failure while reading the body is never retried. The connection pool retires
  # a connection that failed when it is released, so a retry opens a new one.
  #
  # The including class must provide a private `config` method returning the
  # {Configuration}, which supplies the logger.
  #
  # @api private
  module ImmediateRetries
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

    private

    # Send the request through the pool, retrying safe failures at once.
    #
    # @param client_pool [ClientPool] the pool to send through
    # @param request [Request] the request being sent, used for its method
    # @param url [String] the prepared request URL
    # @param headers [Hash] the prepared request headers
    # @param body [Protocol::HTTP::Body::Buffered, nil] the request body
    # @param client [Async::HTTP::Client, nil] the pooled client to use, or nil to
    #   look one up for the URL
    # @return [Protocol::HTTP::Response] the response with its headers read
    def request_with_immediate_retries(client_pool, request, url, headers, body, client: nil)
      attempt = 1

      loop do
        return client_pool.request(request.http_method, url, headers, body, client: client)
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
  end
end
