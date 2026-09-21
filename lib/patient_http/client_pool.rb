# frozen_string_literal: true

module PatientHttp
  # Pool of HTTP clients with least recently used (LRU) eviction.
  #
  # The pool holds one client per host and creates each client on first use. When a
  # new client is needed and the pool is at capacity, the pool closes and removes the
  # least recently used client.
  #
  # @api private
  class ClientPool
    # Supported protocol names mapped to their async-http implementations. Forcing
    # `:http1` also limits the TLS ALPN advertisement to http/1.1, which avoids HTTP/2
    # negotiation with servers and middleboxes that handle it incorrectly.
    PROTOCOLS = {
      http1: Async::HTTP::Protocol::HTTP11,
      http2: Async::HTTP::Protocol::HTTP2
    }.freeze

    # Initializes a new ClientPool.
    #
    # @param max_size [Integer] The maximum number of host clients to keep in the
    #   pool.
    # @param connection_timeout [Numeric, nil] The connection timeout in seconds.
    # @param proxy_url [String, nil] The HTTP or HTTPS proxy URL.
    # @param retries [Integer] The number of retries for a failed request.
    # @param protocol [Symbol, nil] The HTTP protocol to force, either `:http1` or
    #   `:http2`. Use nil to negotiate the protocol with the server.
    # @param connection_limit [Integer, nil] The maximum number of connections per
    #   host. Use nil for an unlimited number.
    # @raise [ArgumentError] If the protocol is not supported.
    def initialize(max_size:, connection_timeout: nil, proxy_url: nil, retries: 3, protocol: nil, connection_limit: nil)
      if protocol && !PROTOCOLS.include?(protocol)
        raise ArgumentError.new("protocol must be one of #{PROTOCOLS.keys.inspect}, got: #{protocol.inspect}")
      end

      @clients = {}
      @max_size = max_size
      @connection_timeout = connection_timeout
      @proxy_url = proxy_url
      @retries = retries
      @protocol = protocol
      @connection_limit = connection_limit
      @mutex = Mutex.new
      @proxy_client = nil
    end

    # @!attribute [r] max_size
    #   @return [Integer] The maximum number of host clients in the pool.
    # @!attribute [r] connection_timeout
    #   @return [Numeric, nil] The connection timeout, in seconds.
    # @!attribute [r] proxy_url
    #   @return [String, nil] The HTTP or HTTPS proxy URL.
    # @!attribute [r] retries
    #   @return [Integer] The number of retries for a failed request.
    # @!attribute [r] protocol
    #   @return [Symbol, nil] The HTTP protocol that the pool forces, either `:http1`
    #     or `:http2`, or nil to negotiate it with the server.
    # @return [Integer, nil] The maximum number of connections per host, or nil for an
    #   unlimited number.
    attr_reader :max_size, :connection_timeout, :proxy_url, :retries, :protocol, :connection_limit

    # Returns the client for the given endpoint, and creates one if the pool does not
    # hold a client for that host yet.
    #
    # @param endpoint [Async::HTTP::Endpoint] The target endpoint.
    # @return [Async::HTTP::Client] The client for the host of the endpoint.
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

    # Makes an HTTP request.
    #
    # @param http_method [String, Symbol] The HTTP method.
    # @param url [String] The request URL.
    # @param headers [Hash] The request headers.
    # @param body [String, nil] The request body.
    # @yield [response] An optional block that processes the response. The response is
    #   closed after the block returns.
    # @return [Protocol::HTTP::Response] The response.
    def request(http_method, url, headers, body, &block)
      endpoint = Async::HTTP::Endpoint.parse(url)
      client = client_for(endpoint)

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

    # Evicts and closes the client for the given URL.
    #
    # The next request to this host establishes a new connection.
    #
    # @param url [String] The request URL whose host client is evicted.
    # @return [void]
    def evict(url)
      endpoint = Async::HTTP::Endpoint.parse(url)
      key = host_key(endpoint)

      @mutex.synchronize do
        client = @clients.delete(key)
        begin
          client&.close
        rescue
          nil
        end
      end
    end

    # Returns the number of clients in the pool.
    #
    # @return [Integer] The number of clients in the pool.
    def size
      @mutex.synchronize { @clients.size }
    end

    private

    def evict_lru
      lru_key, lru_client = @clients.first
      return unless lru_key

      @clients.delete(lru_key)
      begin
        lru_client.close
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
      configured_endpoint = configure_endpoint(endpoint)
      Async::HTTP::Client.new(configured_endpoint, retries: @retries, **client_options)
    end

    def make_proxied_client(endpoint)
      require "async/http/proxy"

      @proxy_client ||= create_proxy_client
      configured_endpoint = configure_endpoint(endpoint)

      proxy = @proxy_client.proxy(configured_endpoint)
      Async::HTTP::Client.new(proxy.wrap_endpoint(configured_endpoint), retries: @retries, **client_options)
    end

    def client_options
      @connection_limit ? {limit: @connection_limit} : {}
    end

    def create_proxy_client
      proxy_endpoint = Async::HTTP::Endpoint.parse(@proxy_url)
      if @connection_timeout
        proxy_endpoint = Async::HTTP::Endpoint.new(proxy_endpoint.url, timeout: @connection_timeout)
      end
      Async::HTTP::Client.new(proxy_endpoint)
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
