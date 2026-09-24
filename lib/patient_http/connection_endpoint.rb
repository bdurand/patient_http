# frozen_string_literal: true

require "delegate"
require "socket"

module PatientHttp
  # Wraps an HTTP endpoint to configure each connection as it's established.
  #
  # If you set a connection timeout, a fiber scheduler timeout bounds the TCP
  # connect and the TLS handshake and raises `IO::TimeoutError`. The timeout isn't
  # set as the socket's `IO#timeout`, because that would also limit every later
  # read and write for the life of the connection. After the connection is
  # established, only the request timeout applies.
  #
  # If you set TCP keepalive options, they're applied to each TCP socket.
  # Keepalive probes keep NAT gateway and stateful firewall mappings alive while
  # a pooled connection is idle. They also let the kernel detect a dead peer, so
  # the connection is retired before a request is sent on it.
  #
  # If you set a TCP user timeout, the kernel aborts a connection whose
  # transmitted data stays unacknowledged for that long. A request sent to a
  # peer that has gone away fails quickly instead of waiting for the request
  # timeout. Data that the peer has acknowledged isn't affected, so a slow
  # response is never cut short. Only Linux supports this option.
  #
  # @api private
  class ConnectionEndpoint < SimpleDelegator
    # @return [Numeric, nil] The number of seconds allowed to establish a connection.
    attr_reader :connection_timeout

    # @return [Hash, nil] The keepalive settings with the keys `:idle`, `:interval`, and `:count`.
    attr_reader :tcp_keepalive

    # @return [Numeric, nil] The number of seconds that transmitted data can stay unacknowledged.
    attr_reader :tcp_user_timeout

    # Creates a wrapper around an endpoint.
    #
    # @param endpoint [Async::HTTP::Endpoint] The endpoint to wrap.
    # @param connection_timeout [Numeric, nil] The number of seconds allowed to establish
    #   a connection, or `nil` for no limit beyond the endpoint's own.
    # @param tcp_keepalive [Hash, nil] The keepalive settings, or `nil` to keep the kernel
    #   defaults. The hash has the keys `:idle` (seconds), `:interval` (seconds), and
    #   `:count` (probes). `:interval` and `:count` are optional.
    # @param tcp_user_timeout [Numeric, nil] The number of seconds that transmitted data
    #   can stay unacknowledged, or `nil` to keep the kernel default.
    def initialize(endpoint, connection_timeout: nil, tcp_keepalive: nil, tcp_user_timeout: nil)
      super(endpoint)
      @connection_timeout = connection_timeout
      @tcp_keepalive = tcp_keepalive
      @tcp_user_timeout = tcp_user_timeout
    end

    # Connects to the wrapped endpoint and configures the socket.
    #
    # @yield [socket] The connected socket. The socket closes when the block returns.
    # @return [IO] The connected socket, if you don't provide a block.
    def connect
      socket = connect_within_timeout
      begin
        apply_tcp_keepalive(socket)
        apply_tcp_user_timeout(socket)
      rescue
        socket.close
        raise
      end

      return socket unless block_given?

      begin
        yield socket
      ensure
        socket.close
      end
    end

    private

    def connect_within_timeout
      task = ::Async::Task.current?
      return __getobj__.connect unless @connection_timeout && task

      task.with_timeout(@connection_timeout, ::IO::TimeoutError, "Connect timed out") do
        __getobj__.connect
      end
    end

    # Keepalive is a TCP feature, so it's skipped for the socket pair behind a
    # proxy tunnel. The kernel constants differ by platform. Linux names the idle
    # time `TCP_KEEPIDLE`, and macOS names it `TCP_KEEPALIVE`. A socket that rejects
    # an option keeps working without it. If the interval or count isn't set, the
    # kernel default applies.
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
      interval = @tcp_keepalive[:interval]
      if interval && defined?(::Socket::TCP_KEEPINTVL)
        raw_socket.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_KEEPINTVL, interval)
      end
      count = @tcp_keepalive[:count]
      if count && defined?(::Socket::TCP_KEEPCNT)
        raw_socket.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_KEEPCNT, count)
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

    # The kernel takes the user timeout in milliseconds. A value of zero restores
    # the kernel default instead of enforcing a limit, so a positive duration is
    # rounded up to at least one millisecond. Platforms without the option keep
    # their default retransmission limits.
    def apply_tcp_user_timeout(socket)
      return unless @tcp_user_timeout && defined?(::Socket::TCP_USER_TIMEOUT)

      raw_socket = tcp_socket(socket)
      return unless raw_socket

      milliseconds = (@tcp_user_timeout * 1000).ceil
      raw_socket.setsockopt(::Socket::IPPROTO_TCP, ::Socket::TCP_USER_TIMEOUT, milliseconds)
    rescue ::SystemCallError
      nil
    end

    # Returns the TCP socket behind a plain or TLS connection. Returns `nil` for a
    # socket that isn't TCP, such as the socket pair behind a proxy tunnel.
    def tcp_socket(socket)
      raw_socket = socket.respond_to?(:to_io) ? socket.to_io : socket
      return nil unless raw_socket.is_a?(::BasicSocket) && raw_socket.local_address.ip?

      raw_socket
    end
  end
end
