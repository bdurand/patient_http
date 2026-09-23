# frozen_string_literal: true

require "delegate"
require "socket"

module PatientHttp
  # Wraps an HTTP endpoint to configure each connection as it is established.
  #
  # The endpoint's `timeout:` option is applied by setting `IO#timeout` on the
  # new socket, which limits the TCP connect and the TLS handshake. Left in
  # place, the same timeout would also limit every later read and write for as
  # long as the connection lives, including reads on a reused keep-alive
  # connection, so a server that pauses longer than the connection timeout
  # before or between response bytes would fail with `IO::TimeoutError` even
  # when the request timeout allows more time. This wrapper clears the socket
  # timeout once the connection is established so the request timeout alone
  # governs the exchange.
  #
  # When TCP keepalive settings are given, they are applied to each TCP socket.
  # Keepalive probes keep the mappings of NAT gateways and stateful firewalls
  # alive while a pooled connection is idle, and let the kernel detect a dead
  # peer so the connection is retired before a request is sent on it.
  #
  # When a TCP user timeout is given, the kernel aborts a connection whose
  # transmitted data stays unacknowledged for that long, so a request sent to a
  # peer that has silently gone away fails quickly instead of waiting for the
  # request timeout. Data the peer has acknowledged is not affected, so a slow
  # response is never cut short. Only Linux supports this option.
  #
  # @api private
  class ConnectionEndpoint < SimpleDelegator
    # @return [Hash, nil] the keepalive settings with :idle, :interval, and :count
    attr_reader :tcp_keepalive

    # @return [Numeric, nil] seconds transmitted data may stay unacknowledged
    attr_reader :tcp_user_timeout

    # @param endpoint [Async::HTTP::Endpoint] the endpoint to wrap
    # @param tcp_keepalive [Hash, nil] keepalive settings with :idle, :interval, and
    #   :count in seconds and probes, or nil to leave the kernel defaults
    # @param tcp_user_timeout [Numeric, nil] seconds transmitted data may stay
    #   unacknowledged, or nil to leave the kernel default
    def initialize(endpoint, tcp_keepalive: nil, tcp_user_timeout: nil)
      super(endpoint)
      @tcp_keepalive = tcp_keepalive
      @tcp_user_timeout = tcp_user_timeout
    end

    # Connect to the wrapped endpoint and configure the socket.
    #
    # @yield [socket] the connected socket, closed when the block returns
    # @return [IO] the connected socket when no block is given
    def connect
      socket = __getobj__.connect
      clear_timeout(socket)
      apply_tcp_keepalive(socket)
      apply_tcp_user_timeout(socket)

      return socket unless block_given?

      begin
        yield socket
      ensure
        socket.close
      end
    end

    private

    def clear_timeout(socket)
      if socket.respond_to?(:timeout=)
        socket.timeout = nil
      end
    end

    # Keepalive is a TCP feature, so it is skipped for the socket pair behind a
    # proxy tunnel. The kernel constants differ by platform: Linux names the idle
    # time TCP_KEEPIDLE, macOS names it TCP_KEEPALIVE. A socket that rejects an
    # option keeps working without it.
    #
    # Top-level constants are written with a leading `::` because Delegator
    # descends from BasicObject, where `defined?` cannot see them.
    def apply_tcp_keepalive(socket)
      return unless @tcp_keepalive

      raw_socket = tcp_socket(socket)
      return unless raw_socket

      raw_socket.setsockopt(::Socket::SOL_SOCKET, ::Socket::SO_KEEPALIVE, true)
      if (idle_option = keepalive_idle_option)
        raw_socket.setsockopt(::Socket::IPPROTO_TCP, idle_option, @tcp_keepalive[:idle])
      end
      if defined?(::Socket::TCP_KEEPINTVL)
        raw_socket.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_KEEPINTVL, @tcp_keepalive[:interval])
      end
      if defined?(::Socket::TCP_KEEPCNT)
        raw_socket.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_KEEPCNT, @tcp_keepalive[:count])
      end
    rescue ::SystemCallError
      nil
    end

    def keepalive_idle_option
      if defined?(::Socket::TCP_KEEPIDLE)
        ::Socket::TCP_KEEPIDLE
      elsif defined?(::Socket::TCP_KEEPALIVE)
        ::Socket::TCP_KEEPALIVE
      end
    end

    # The kernel takes the user timeout in milliseconds. Platforms without the
    # option keep their default retransmission limits.
    def apply_tcp_user_timeout(socket)
      return unless @tcp_user_timeout && defined?(::Socket::TCP_USER_TIMEOUT)

      raw_socket = tcp_socket(socket)
      return unless raw_socket

      milliseconds = (@tcp_user_timeout * 1000).round
      raw_socket.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_USER_TIMEOUT, milliseconds)
    rescue ::SystemCallError
      nil
    end

    # The TCP socket behind a plain or TLS connection, or nil for a socket that
    # is not TCP, such as the socket pair behind a proxy tunnel.
    def tcp_socket(socket)
      raw_socket = socket.respond_to?(:to_io) ? socket.to_io : socket
      return nil unless raw_socket.is_a?(::BasicSocket) && raw_socket.local_address.ip?

      raw_socket
    end
  end
end
