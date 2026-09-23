# frozen_string_literal: true

module PatientHttp
  # Pool of HTTP clients with LRU eviction.
  #
  # Maintains a pool of clients lazily instantiated for each host. The pool
  # is capped with an LRU algorithm - when a new client is needed and the
  # pool is at capacity, the least recently used client is closed and removed.
  class ClientPool
    # Supported protocol names mapped to their async-http implementations. Forcing
    # :http1 also limits the TLS ALPN advertisement to http/1.1, which avoids
    # HTTP/2 negotiation with servers and middleboxes that mishandle it.
    PROTOCOLS = {
      http1: Async::HTTP::Protocol::HTTP11,
      http2: Async::HTTP::Protocol::HTTP2
    }.freeze

    def initialize(max_size:, connection_timeout: nil, proxy_url: nil, retries: 3, protocol: nil,
      connection_limit: nil, tcp_keepalive: nil, tcp_user_timeout: nil)
      if protocol && !PROTOCOLS.include?(protocol)
        raise ArgumentError.new("protocol must be one of #{PROTOCOLS.keys.inspect}, got: #{protocol.inspect}")
      end

      @clients = {}
      @max_size = max_size
      @connection_timeout = connection_timeout
      @tcp_keepalive = tcp_keepalive
      @tcp_user_timeout = tcp_user_timeout
      @proxy_url = proxy_url
      @retries = retries
      @protocol = protocol
      @connection_limit = connection_limit
      @mutex = Mutex.new
      @proxy_client = nil
    end

    attr_reader :max_size, :connection_timeout, :proxy_url, :retries, :protocol, :connection_limit,
      :tcp_keepalive, :tcp_user_timeout

    # Get or create a client for the given endpoint.
    #
    # @param endpoint [Async::HTTP::Endpoint] the target endpoint
    # @return [Async::HTTP::Client] the client for the endpoint's host
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

    # Make a request.
    #
    # @param http_method [String, Symbol] HTTP method
    # @param url [String] request URL
    # @param headers [Hash] request headers
    # @param body [String, nil] request body
    # @param client [Async::HTTP::Client, nil] the pooled client to send through,
    #   normally the one {#client_for} returned for the URL; nil looks it up
    # @param block [Proc] optional block to process the response
    # @return [Protocol::HTTP::Response] the response
    def request(http_method, url, headers, body, client: nil, &block)
      endpoint = Async::HTTP::Endpoint.parse(url)
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

    # Close all clients and release resources.
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
    end

    # Evict and close the client for the given URL.
    #
    # This forces a new connection to be established on the next request to this host.
    # When the client that failed is given, only that client is evicted: a
    # replacement installed for the host after an earlier eviction is left alone,
    # so a late failure on the old client cannot discard a healthy new one.
    #
    # @param url [String] the request URL whose host client should be evicted
    # @param client [Async::HTTP::Client, nil] the client that failed, or nil to
    #   evict whichever client the pool currently holds for the host
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

    # @return [Integer] number of clients in the pool
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
    def close_later(client)
      Async do
        client.close
      rescue
        nil
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
      @proxy_url ? make_proxied_client(endpoint) : make_direct_client(endpoint)
    end

    def make_direct_client(endpoint)
      configured_endpoint = connectable_endpoint(configure_endpoint(endpoint))
      Async::HTTP::Client.new(configured_endpoint, retries: @retries, **client_options)
    end

    def make_proxied_client(endpoint)
      require "async/http/proxy"

      @proxy_client ||= create_proxy_client
      configured_endpoint = configure_endpoint(endpoint)

      proxy = @proxy_client.proxy(configured_endpoint)
      tunneled_endpoint = connectable_endpoint(proxy.wrap_endpoint(configured_endpoint))
      Async::HTTP::Client.new(tunneled_endpoint, retries: @retries, **client_options)
    end

    def client_options
      @connection_limit ? {limit: @connection_limit} : {}
    end

    def create_proxy_client
      proxy_endpoint = Async::HTTP::Endpoint.parse(@proxy_url)
      if @connection_timeout
        proxy_endpoint = Async::HTTP::Endpoint.new(proxy_endpoint.url, timeout: @connection_timeout)
      end
      Async::HTTP::Client.new(connectable_endpoint(proxy_endpoint))
    end

    # The connection timeout reaches the socket as an IO timeout that would
    # otherwise apply to every read and write for the life of the connection.
    # The wrapper limits it to establishing the connection, and applies the
    # TCP keepalive and user timeout settings to each new socket.
    def connectable_endpoint(endpoint)
      return endpoint unless @connection_timeout || @tcp_keepalive || @tcp_user_timeout

      ConnectionEndpoint.new(
        endpoint,
        connection_timeout: @connection_timeout,
        tcp_keepalive: @tcp_keepalive,
        tcp_user_timeout: @tcp_user_timeout
      )
    end

    def configure_endpoint(endpoint)
      options = {}
      options[:timeout] = @connection_timeout if @connection_timeout
      options[:protocol] = PROTOCOLS.fetch(@protocol) if @protocol
      return endpoint if options.empty?

      Async::HTTP::Endpoint.new(endpoint.url, **options)
    end
  end
end
