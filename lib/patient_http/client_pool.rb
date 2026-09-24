# frozen_string_literal: true

module PatientHttp
  # A pool of HTTP clients, one for each host.
  #
  # A client is created when a host first needs one. When the pool is full and
  # a new client is needed, the least recently used client is closed and
  # removed.
  #
  # @api private
  class ClientPool
    # Supported protocol names mapped to their async-http implementations. Forcing
    # :http1 also limits the TLS ALPN advertisement to http/1.1, which avoids
    # HTTP/2 negotiation with servers and middleboxes that mishandle it.
    PROTOCOLS = {
      http1: Async::HTTP::Protocol::HTTP11,
      http2: Async::HTTP::Protocol::HTTP2
    }.freeze

    class << self
      # Builds a pool with the connection settings from a configuration.
      #
      # @param config [Configuration] The configuration to read settings from.
      # @return [ClientPool] The new pool.
      def from_config(config)
        new(
          max_size: config.connection_pool_size,
          connection_timeout: config.connection_timeout,
          proxy_url: config.proxy_url,
          retries: config.retries,
          protocol: config.protocol,
          connection_limit: config.max_connections_per_host,
          tcp_keepalive: config.tcp_keepalive,
          tcp_user_timeout: config.tcp_user_timeout
        )
      end
    end

    # Creates a client pool.
    #
    # @param max_size [Integer] The maximum number of host clients in the pool.
    # @param connection_timeout [Numeric, nil] The timeout in seconds to open a
    #   connection.
    # @param proxy_url [String, nil] The HTTP or HTTPS proxy URL.
    # @param retries [Integer] The number of retries for failed requests.
    # @param protocol [Symbol, nil] The HTTP protocol: `:http1` or `:http2`.
    # @param connection_limit [Integer, nil] The maximum number of connections
    #   to each host.
    # @param tcp_keepalive [Integer, Hash, nil] The TCP keepalive settings.
    # @param tcp_user_timeout [Numeric, nil] The TCP user timeout in seconds.
    # @raise [ArgumentError] If the protocol isn't supported.
    def initialize(max_size:, connection_timeout: nil, proxy_url: nil, retries: 3, protocol: nil,
      connection_limit: nil, tcp_keepalive: nil, tcp_user_timeout: nil)
      if protocol && !PROTOCOLS.include?(protocol)
        raise ArgumentError.new("protocol must be one of #{PROTOCOLS.keys.inspect}, got: #{protocol.inspect}")
      end

      @clients = {}
      @max_size = max_size
      @connection_timeout = connection_timeout
      @tcp_keepalive = tcp_keepalive.is_a?(Numeric) ? {idle: tcp_keepalive} : tcp_keepalive
      @tcp_user_timeout = tcp_user_timeout
      @proxy_url = proxy_url
      @retries = retries
      @protocol = protocol
      @connection_limit = connection_limit
      @mutex = Mutex.new
      @proxy_client = nil
      @closing_tasks = []
      @closing_mutex = Mutex.new
    end

    # @return [Object] The connection settings that the pool was created with.
    attr_reader :max_size, :connection_timeout, :proxy_url, :retries, :protocol, :connection_limit,
      :tcp_keepalive, :tcp_user_timeout

    # Returns or creates a client for the given endpoint.
    #
    # @param endpoint [Async::HTTP::Endpoint] The target endpoint.
    # @return [Async::HTTP::Client] The client for the endpoint's host.
    def client_for(endpoint)
      key = host_key(endpoint)

      @mutex.synchronize do
        if @clients.key?(key)
          # Move to end (most recently used) by re-inserting
          client = @clients.delete(key)
          @clients[key] = client
          return client
        end

        evict_lru if @clients.size >= @max_size
        @clients[key] = make_client(endpoint)
      end
    end

    # Makes a request.
    #
    # @param http_method [String, Symbol] HTTP method.
    # @param url [String, Async::HTTP::Endpoint] Request URL, or the endpoint
    #   already parsed from it.
    # @param headers [Hash] Request headers.
    # @param body [String, nil] Request body.
    # @param client [Async::HTTP::Client, nil] The pooled client to send through,
    #   normally the one {#client_for} returned for the URL; nil looks it up.
    # @param block [Proc] Optional block to process the response.
    # @return [Protocol::HTTP::Response] The response.
    def request(http_method, url, headers, body, client: nil, &block)
      endpoint = url.is_a?(Async::HTTP::Endpoint) ? url : Async::HTTP::Endpoint.parse(url)
      client ||= client_for(endpoint)

      verb = http_method.to_s.upcase

      options = {
        headers: headers,
        body: body,
        scheme: endpoint.scheme,
        authority: endpoint.authority
      }

      request = ::Protocol::HTTP::Request[verb, endpoint.path, **options]
      response = client.call(request)

      return response unless block_given?

      begin
        yield response
      ensure
        response.close
      end
    end

    # Closes all clients and releases their resources.
    #
    # Clients evicted earlier whose close is still waiting for their in-flight
    # requests are waited on as well, so no connection outlives the pool.
    #
    # @return [void]
    def close
      @mutex.synchronize do
        @clients.each_value do |client|
          client.close
        rescue
          nil
        end
        @clients.clear

        begin
          @proxy_client&.close
        rescue
          nil
        end
        @proxy_client = nil
      end

      pending = @closing_mutex.synchronize { @closing_tasks.dup }
      pending.each do |task|
        task.wait
      rescue StandardError, Async::Stop
        nil
      end
    end

    # Evicts and closes the client for the host of a URL.
    #
    # This forces a new connection to be established on the next request to this host.
    # When the client that failed is given, only that client is evicted: a
    # replacement installed for the host after an earlier eviction is left alone,
    # so a late failure on the old client cannot discard a healthy new one.
    #
    # @param url [String] The request URL whose host client should be evicted.
    # @param client [Async::HTTP::Client, nil] The client that failed, or nil to
    #   evict whichever client the pool currently holds for the host.
    # @return [void]
    def evict(url, client = nil)
      endpoint = Async::HTTP::Endpoint.parse(url)
      key = host_key(endpoint)

      evicted = @mutex.synchronize do
        if client.nil? || @clients[key].equal?(client)
          @clients.delete(key)
        end
      end
      close_later(evicted) if evicted
    end

    # @return [Integer] Number of clients in the pool.
    def size
      @mutex.synchronize { @clients.size }
    end

    private

    def evict_lru
      lru_key, lru_client = @clients.first
      return unless lru_key

      @clients.delete(lru_key)
      close_later(lru_client)
    end

    # Closing a client waits for its in-flight requests to finish before closing
    # their connections. Evictions run on a request task while other requests are
    # waiting to be dispatched, so the close runs in its own task and neither the
    # evicting request nor the pool mutex waits for it. Outside a reactor the
    # block runs inline.
    #
    # The task is transient so it does not hold the evicting request's task
    # open, and it is tracked so {#close} can wait for it. The tracking list has
    # its own mutex because evictions spawn the task while holding the pool mutex.
    def close_later(client)
      task = Async(transient: true) do |current|
        client.close
      rescue
        nil
      ensure
        @closing_mutex.synchronize { @closing_tasks.delete(current) }
      end

      unless task.finished?
        @closing_mutex.synchronize { @closing_tasks << task }
      end
    end

    def host_key(endpoint)
      url = endpoint.url.dup
      url.path = ""
      url.fragment = nil
      url.query = nil
      url
    end

    def make_client(endpoint)
      # Response bodies are decoded by ResponseReader on a completion worker
      # thread instead of a Protocol::HTTP::AcceptEncoding wrapper, so the
      # reactor thread never pays for inflating compressed bodies.
      #
      # Each client makes a single attempt per request. Retries, bounded by the
      # pool's retries setting, are applied by ImmediateRetries so that only
      # one layer decides when a request is sent again.
      @proxy_url ? make_proxied_client(endpoint) : make_direct_client(endpoint)
    end

    def make_direct_client(endpoint)
      configured_endpoint = connectable_endpoint(configure_endpoint(endpoint))
      Async::HTTP::Client.new(configured_endpoint, retries: 1, **client_options)
    end

    def make_proxied_client(endpoint)
      require "async/http/proxy"

      @proxy_client ||= create_proxy_client
      configured_endpoint = configure_endpoint(endpoint)

      proxy = @proxy_client.proxy(configured_endpoint)
      tunneled_endpoint = connectable_endpoint(proxy.wrap_endpoint(configured_endpoint))
      Async::HTTP::Client.new(tunneled_endpoint, retries: 1, **client_options)
    end

    def client_options
      @connection_limit ? {limit: @connection_limit} : {}
    end

    def create_proxy_client
      proxy_endpoint = Async::HTTP::Endpoint.parse(@proxy_url)
      Async::HTTP::Client.new(connectable_endpoint(proxy_endpoint))
    end

    # The connection timeout is enforced by the wrapper around establishing the
    # connection rather than passed to the endpoint, which would set it as an IO
    # timeout on every read and write for the life of the connection. The
    # wrapper also applies the TCP keepalive and user timeout settings to each
    # new socket.
    def connectable_endpoint(endpoint)
      unless @connection_timeout || @tcp_keepalive || @tcp_user_timeout
        return endpoint
      end

      ConnectionEndpoint.new(
        endpoint,
        connection_timeout: @connection_timeout,
        tcp_keepalive: @tcp_keepalive,
        tcp_user_timeout: @tcp_user_timeout
      )
    end

    def configure_endpoint(endpoint)
      options = {}
      options[:protocol] = PROTOCOLS.fetch(@protocol) if @protocol
      return endpoint if options.empty?

      Async::HTTP::Endpoint.new(endpoint.url, **options)
    end
  end
end
