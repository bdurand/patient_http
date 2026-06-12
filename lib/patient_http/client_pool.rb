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

    def initialize(max_size:, connection_timeout: nil, proxy_url: nil, retries: 3, protocol: nil)
      if protocol && !PROTOCOLS.include?(protocol)
        raise ArgumentError.new("protocol must be one of #{PROTOCOLS.keys.inspect}, got: #{protocol.inspect}")
      end

      @clients = {}
      @max_size = max_size
      @connection_timeout = connection_timeout
      @proxy_url = proxy_url
      @retries = retries
      @protocol = protocol
      @mutex = Mutex.new
      @proxy_client = nil
    end

    attr_reader :max_size, :connection_timeout, :proxy_url, :retries, :protocol

    # Get or create a client for the given endpoint.
    #
    # @param endpoint [Async::HTTP::Endpoint] the target endpoint
    # @return [Protocol::HTTP::AcceptEncoding] wrapped client
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
    # @param block [Proc] optional block to process the response
    # @return [Protocol::HTTP::Response] the response
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
    #
    # @param url [String] the request URL whose host client should be evicted
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

    # @return [Integer] number of clients in the pool
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
      client = @proxy_url ? make_proxied_client(endpoint) : make_direct_client(endpoint)
      ::Protocol::HTTP::AcceptEncoding.new(client)
    end

    def make_direct_client(endpoint)
      configured_endpoint = configure_endpoint(endpoint)
      Async::HTTP::Client.new(configured_endpoint, retries: @retries)
    end

    def make_proxied_client(endpoint)
      require "async/http/proxy"

      @proxy_client ||= create_proxy_client
      configured_endpoint = configure_endpoint(endpoint)

      proxy = @proxy_client.proxy(configured_endpoint)
      Async::HTTP::Client.new(proxy.wrap_endpoint(configured_endpoint), retries: @retries)
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
