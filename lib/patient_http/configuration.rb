# frozen_string_literal: true

module PatientHttp
  # The configuration for the processor and its HTTP connections.
  #
  # The options include connection limits, timeouts, redirects, secrets,
  # preprocessors, encryption, and payload stores. This class doesn't depend on
  # a job system. Job system integration gems subclass it to add their own
  # options.
  #
  # @example
  #   PatientHttp.configure do |config|
  #     config.max_connections = 512
  #     config.request_timeout = 120
  #   end
  class Configuration
    # The salt for key derivation. Changing it makes existing encrypted data
    # unreadable.
    SALT = "patient_http_payload_encryption"
    private_constant :SALT

    # The default size in bytes above which a serialized payload goes to a
    # payload store instead of the job queue.
    DEFAULT_PAYLOAD_STORE_THRESHOLD = 64 * 1024 # 64KB

    # @return [Integer] The maximum number of concurrent requests.
    attr_reader :max_connections

    # @return [Integer, nil] The maximum number of connections to each host, or
    #   `nil` for no limit.
    attr_reader :max_connections_per_host

    # @return [Integer] The number of threads that decode responses and deliver
    #   results.
    attr_reader :completion_threads

    # @return [Integer] The number of times to retry result delivery after it
    #   fails. A retry calls the task handler again, so handlers must be
    #   idempotent.
    attr_reader :completion_retries

    # @return [Numeric] The default request timeout in seconds.
    attr_reader :request_timeout

    # @return [Numeric] The graceful shutdown timeout in seconds.
    attr_reader :shutdown_timeout

    # @return [Integer] The maximum response body size in bytes.
    attr_reader :max_response_size

    # @return [String, nil] The default `User-Agent` header value.
    attr_accessor :user_agent

    # @return [Boolean] Whether non-2xx responses go to the `on_error` callback
    #   as an {HttpError} by default.
    attr_accessor :raise_error_responses

    # @return [Integer] The maximum number of redirects to follow. If `0`,
    #   redirects aren't followed.
    attr_reader :max_redirects

    # @return [Boolean] Whether to follow a redirect that changes the HTTP
    #   method, such as POST to GET on a 302. If `false`, the redirect response
    #   is the result.
    attr_reader :follow_method_changing_redirects

    # @return [Array<String>] The lowercase names of headers to remove from all
    #   redirected requests.
    attr_reader :redirect_strip_headers

    # @return [Integer] The maximum number of hosts whose connections are kept
    #   open at the same time.
    attr_reader :connection_pool_size

    # @return [Numeric, nil] The timeout in seconds to open a connection,
    #   including the TCP connect and the TLS handshake. It doesn't limit the
    #   wait for a response. `request_timeout` sets that limit.
    attr_reader :connection_timeout

    # @return [Hash, nil] The TCP keepalive settings for each connection, or `nil`
    #   if the kernel sends no probes. The hash has the `:idle` seconds before
    #   the first probe, the `:interval` seconds between probes, and the `:count`
    #   of probes before the connection is closed.
    attr_reader :tcp_keepalive

    # @return [Numeric, nil] The seconds that sent data can stay unacknowledged
    #   before the kernel closes the connection. This value sets
    #   `TCP_USER_TIMEOUT`, which is available only on Linux. A request to a peer
    #   that stopped without notice then fails without waiting for the request
    #   timeout. Acknowledged data isn't affected, so a slow response continues.
    attr_reader :tcp_user_timeout

    # @return [String, nil] The HTTP or HTTPS proxy URL. The URL can include a
    #   user name and password.
    attr_reader :proxy_url

    # @return [Integer] The number of retries for failed requests.
    attr_reader :retries

    # @return [Symbol, nil] The HTTP protocol: `:http1` or `:http2`. If `nil`, the
    #   protocol is negotiated with the server, and HTTP/2 is preferred for
    #   HTTPS.
    attr_reader :protocol

    # @return [SecretManager] The manager for the registered secrets.
    attr_reader :secret_manager

    # @return [Integer] The size in bytes above which a serialized payload goes
    #   to the registered payload store instead of the job queue.
    attr_reader :payload_store_threshold

    # Creates a configuration.
    #
    # @param max_connections [Integer] The maximum number of concurrent requests.
    # @param request_timeout [Numeric] The default request timeout in seconds.
    # @param shutdown_timeout [Numeric] The graceful shutdown timeout in seconds.
    # @param logger [Logger, nil] The logger. If `nil`, errors are logged to
    #   standard error.
    # @param max_response_size [Integer] The maximum response body size in bytes.
    # @param user_agent [String, nil] The default `User-Agent` header value.
    # @param raise_error_responses [Boolean] Whether non-2xx responses go to the
    #   `on_error` callback as an {HttpError} by default.
    # @param max_redirects [Integer] The maximum number of redirects to follow. If
    #   `0`, redirects aren't followed.
    # @param follow_method_changing_redirects [Boolean] Whether to follow a
    #   redirect that changes the HTTP method, such as POST to GET on a 301, 302,
    #   or 303 response. If `false`, the redirect response is the result.
    # @param redirect_strip_headers [String, Array<String>] The names of headers to
    #   remove from all redirected requests. Names are case insensitive.
    # @param connection_pool_size [Integer] The maximum number of hosts whose
    #   connections are kept open.
    # @param connection_timeout [Numeric, nil] The timeout in seconds to open a
    #   connection, including the TCP connect and the TLS handshake.
    # @param tcp_keepalive [Integer, Hash, nil] The idle seconds before the first
    #   keepalive probe, or a hash with `:idle`, `:interval`, and `:count`. If
    #   `nil`, the kernel sends no probes.
    # @param tcp_user_timeout [Numeric, nil] The seconds that sent data can stay
    #   unacknowledged before the kernel closes the connection. Linux only. If
    #   `nil`, the kernel default applies.
    # @param proxy_url [String, nil] The HTTP or HTTPS proxy URL.
    # @param retries [Integer] The number of retries for failed requests.
    # @param protocol [Symbol, nil] The HTTP protocol: `:http1` or `:http2`. If
    #   `nil`, the protocol is negotiated.
    # @param encryption_key [String, Array<String>, nil] The encryption key, or an
    #   array of keys for key rotation. See {#encryption_key=}.
    # @param max_connections_per_host [Integer, nil] The maximum number of
    #   connections to each host, or `nil` for no limit.
    # @param completion_threads [Integer] The number of threads that decode
    #   responses and deliver results.
    # @param completion_retries [Integer] The number of times to retry result
    #   delivery after it fails. A retry calls `TaskHandler#on_complete` or
    #   `TaskHandler#on_error` again. If `0`, the first failure is reported
    #   without a retry.
    # @param payload_store_threshold [Integer, nil] The size in bytes above which
    #   a serialized payload goes to the registered payload store.
    # @raise [ArgumentError] If an option isn't valid.
    def initialize(
      max_connections: 256,
      request_timeout: 60,
      shutdown_timeout: 30,
      logger: nil,
      max_response_size: 1024 * 1024,
      user_agent: "PatientHttp",
      raise_error_responses: false,
      max_redirects: 5,
      follow_method_changing_redirects: true,
      redirect_strip_headers: [],
      connection_pool_size: 100,
      connection_timeout: nil,
      tcp_keepalive: nil,
      tcp_user_timeout: nil,
      proxy_url: nil,
      retries: 3,
      protocol: nil,
      encryption_key: nil,
      max_connections_per_host: nil,
      completion_threads: 2,
      completion_retries: 2,
      payload_store_threshold: DEFAULT_PAYLOAD_STORE_THRESHOLD
    )
      @mutex = Mutex.new

      # Initialize payload store configuration
      @payload_stores = {}
      @default_payload_store_name = nil

      # Initialize secret configuration
      @secrets = {}
      @secret_manager = SecretManager.new

      # Initialize preprocessor registry
      @preprocessors = {}

      @encryptor = nil

      self.max_connections = max_connections
      self.request_timeout = request_timeout
      self.shutdown_timeout = shutdown_timeout
      self.logger = logger || Logger.new($stderr, level: Logger::ERROR)
      self.max_response_size = max_response_size
      self.user_agent = user_agent
      self.raise_error_responses = raise_error_responses
      self.max_redirects = max_redirects
      self.follow_method_changing_redirects = follow_method_changing_redirects
      self.redirect_strip_headers = redirect_strip_headers
      self.connection_pool_size = connection_pool_size
      self.connection_timeout = connection_timeout
      self.tcp_keepalive = tcp_keepalive
      self.tcp_user_timeout = tcp_user_timeout
      self.proxy_url = proxy_url
      self.retries = retries
      self.protocol = protocol
      self.encryption_key = encryption_key
      self.max_connections_per_host = max_connections_per_host
      self.completion_threads = completion_threads
      self.completion_retries = completion_retries
      self.payload_store_threshold = payload_store_threshold
    end

    # @return [Logger] The logger for processor events. The default logger
    #   writes errors to standard error.
    attr_accessor :logger

    # Sets the maximum number of concurrent requests.
    #
    # @param value [Integer] A positive number.
    # @return [void]
    # @raise [ArgumentError] If the value isn't positive.
    def max_connections=(value)
      validate_positive(:max_connections, value)
      @max_connections = value
    end

    # Sets the maximum number of connections to each host.
    #
    # @param value [Integer, nil] A positive integer, or `nil` for no limit.
    # @return [void]
    # @raise [ArgumentError] If the value isn't `nil` or a positive integer.
    def max_connections_per_host=(value)
      if value.nil?
        @max_connections_per_host = nil
        return
      end

      validate_positive_integer(:max_connections_per_host, value)
      @max_connections_per_host = value
    end

    # Sets the number of threads that decode responses and deliver results. If
    # the value is greater than 1, results are delivered concurrently, so task
    # handlers must be thread-safe.
    #
    # @param value [Integer] A positive integer.
    # @return [void]
    # @raise [ArgumentError] If the value isn't a positive integer.
    def completion_threads=(value)
      validate_positive_integer(:completion_threads, value)
      @completion_threads = value
    end

    # Sets the number of times to retry result delivery after it fails.
    #
    # @param value [Integer] A non-negative integer. If `0`, the first failure is
    #   reported without a retry.
    # @return [void]
    # @raise [ArgumentError] If the value isn't a non-negative integer.
    def completion_retries=(value)
      validate_non_negative_integer(:completion_retries, value)
      @completion_retries = value
    end

    # Sets the size in bytes above which a serialized payload goes to the
    # registered payload store instead of the job queue. This option has an
    # effect only when a payload store is registered with
    # {#register_payload_store}.
    #
    # @param value [Integer, nil] The size in bytes, or `nil` to use the default.
    # @return [void]
    # @raise [ArgumentError] If the value isn't `nil` or a positive integer.
    def payload_store_threshold=(value)
      value = DEFAULT_PAYLOAD_STORE_THRESHOLD if value.nil?
      validate_positive_integer(:payload_store_threshold, value)
      @payload_store_threshold = value
    end

    # Sets the default request timeout.
    #
    # @param value [Numeric] A positive number of seconds.
    # @return [void]
    # @raise [ArgumentError] If the value isn't positive.
    def request_timeout=(value)
      validate_positive(:request_timeout, value)
      @request_timeout = value
    end

    # Sets the graceful shutdown timeout. Keep it less than the stop timeout of
    # the process supervisor, so that in-flight requests finish before a hard
    # kill.
    #
    # @param value [Numeric] A positive number of seconds.
    # @return [void]
    # @raise [ArgumentError] If the value isn't positive.
    def shutdown_timeout=(value)
      validate_positive(:shutdown_timeout, value)
      @shutdown_timeout = value
    end

    # Sets the maximum response body size. For a compressed response, the limit
    # applies to the decompressed body. A larger response raises
    # {ResponseTooLargeError}.
    #
    # @param value [Integer] A positive number of bytes.
    # @return [void]
    # @raise [ArgumentError] If the value isn't positive.
    def max_response_size=(value)
      validate_positive(:max_response_size, value)
      @max_response_size = value
    end

    # Sets the maximum number of redirects to follow.
    #
    # @param value [Integer] A non-negative integer. If `0`, redirects aren't
    #   followed.
    # @return [void]
    # @raise [ArgumentError] If the value isn't a non-negative integer.
    def max_redirects=(value)
      validate_non_negative_integer(:max_redirects, value)
      @max_redirects = value
    end

    # Sets whether to follow a redirect that changes the HTTP method, such as
    # POST to GET on a 302.
    #
    # @param value [Boolean] If `false`, the redirect response is the result.
    # @return [void]
    # @raise [ArgumentError] If the value isn't `true` or `false`.
    def follow_method_changing_redirects=(value)
      unless value == true || value == false
        raise ArgumentError.new("follow_method_changing_redirects must be true or false, got: #{value.inspect}")
      end

      @follow_method_changing_redirects = value
    end

    # Sets the names of headers to remove from all redirected requests. The
    # `Authorization` and `Cookie` headers are always removed on cross-origin
    # redirects.
    #
    # @param value [String, Array<String>, nil] The header names. Names are case
    #   insensitive.
    # @return [void]
    def redirect_strip_headers=(value)
      @redirect_strip_headers = RedirectHelper.normalize_header_names(value)
    end

    # Sets the maximum number of hosts whose connections are kept open.
    #
    # @param value [Integer] A positive integer.
    # @return [void]
    # @raise [ArgumentError] If the value isn't a positive integer.
    def connection_pool_size=(value)
      validate_positive_integer(:connection_pool_size, value)
      @connection_pool_size = value
    end

    # Sets the timeout to open a connection, including the TCP connect and the
    # TLS handshake. It doesn't limit the wait for a response.
    #
    # @param value [Numeric, nil] A positive number of seconds, or `nil` for no
    #   limit.
    # @return [void]
    # @raise [ArgumentError] If the value isn't `nil` or positive.
    def connection_timeout=(value)
      if value.nil?
        @connection_timeout = nil
        return
      end

      validate_positive(:connection_timeout, value)
      @connection_timeout = value
    end

    # Sets TCP keepalive for pooled connections. The kernel sends probes on an
    # idle connection, which keeps NAT and firewall mappings open and finds dead
    # peers.
    #
    # @param value [Integer, Hash, nil] The idle seconds before the first probe,
    #   or a hash with `:idle` and the optional `:interval` (default 10 seconds)
    #   and `:count` (default 3 probes). If `nil`, the kernel sends no probes.
    # @return [void]
    # @raise [ArgumentError] If the hash has an unknown key, or a value isn't a
    #   positive integer.
    def tcp_keepalive=(value)
      if value.nil?
        @tcp_keepalive = nil
        return
      end

      settings = value.is_a?(Hash) ? value.transform_keys(&:to_sym) : {idle: value}
      unknown = settings.keys - [:idle, :interval, :count]
      unless unknown.empty?
        raise ArgumentError.new("tcp_keepalive has unknown keys: #{unknown.inspect}")
      end

      settings = {interval: 10, count: 3}.merge(settings)
      validate_positive_integer(:tcp_keepalive_idle, settings[:idle])
      validate_positive_integer(:tcp_keepalive_interval, settings[:interval])
      validate_positive_integer(:tcp_keepalive_count, settings[:count])
      @tcp_keepalive = settings.slice(:idle, :interval, :count).freeze
    end

    # Sets the seconds that sent data can stay unacknowledged before the kernel
    # closes the connection. The value applies only on platforms that support
    # `TCP_USER_TIMEOUT`, which is Linux.
    #
    # @param value [Numeric, nil] A positive number of seconds, or `nil` to use
    #   the kernel default.
    # @return [void]
    # @raise [ArgumentError] If the value isn't `nil` or positive.
    def tcp_user_timeout=(value)
      if value.nil?
        @tcp_user_timeout = nil
        return
      end

      validate_positive(:tcp_user_timeout, value)
      @tcp_user_timeout = value
    end

    # Sets the HTTP or HTTPS proxy URL.
    #
    # @param value [String, nil] The proxy URL, or `nil` for no proxy. The URL
    #   can include a user name and password, for example
    #   `http://user:pass@proxy.example.com:8080`.
    # @return [void]
    # @raise [ArgumentError] If the value isn't a valid HTTP or HTTPS URL.
    def proxy_url=(value)
      if value.nil?
        @proxy_url = nil
        return
      end

      validate_url(:proxy_url, value)
      @proxy_url = value
    end

    # Sets the number of retries for failed requests.
    #
    # @param value [Integer] A non-negative integer.
    # @return [void]
    # @raise [ArgumentError] If the value isn't a non-negative integer.
    def retries=(value)
      validate_non_negative_integer(:retries, value)
      @retries = value
    end

    # Sets the HTTP protocol. The `:http1` value also limits the TLS ALPN
    # advertisement to `http/1.1`, which can work around proxies that intercept
    # SSL and don't handle HTTP/2 correctly.
    #
    # @param value [Symbol, String, nil] `:http1` or `:http2`, or `nil` to
    #   negotiate the protocol with the server.
    # @return [void]
    # @raise [ArgumentError] If the value isn't a supported protocol.
    def protocol=(value)
      if value.nil?
        @protocol = nil
        return
      end

      value = value.to_sym if value.is_a?(String)
      unless ClientPool::PROTOCOLS.key?(value)
        raise ArgumentError.new("protocol must be one of #{ClientPool::PROTOCOLS.keys.inspect}, got: #{value.inspect}")
      end

      @protocol = value
    end

    # Sets the callable that encrypts serialized payloads. Set {#decryption} as
    # well.
    #
    # @param callable [#call, nil] An object that takes the bytes as a String and
    #   returns the encrypted bytes. Omit it when you give a block.
    # @yield [data] Returns the encrypted bytes. Omit it when you give a
    #   callable.
    # @yieldparam data [String] The bytes to encrypt.
    # @return [void]
    # @raise [ArgumentError] If you give both a callable and a block, or if the
    #   callable doesn't respond to `call`.
    def encryption(callable = nil, &block)
      @encryption = resolve_callable(:encryption, callable, &block)
      @encryptor = nil
    end

    # Sets the callable that decrypts serialized payloads. Set {#encryption} as
    # well.
    #
    # @param callable [#call, nil] An object that takes the encrypted bytes as a
    #   String and returns the decrypted bytes. Omit it when you give a block.
    # @yield [data] Returns the decrypted bytes. Omit it when you give a
    #   callable.
    # @yieldparam data [String] The bytes to decrypt.
    # @return [void]
    # @raise [ArgumentError] If you give both a callable and a block, or if the
    #   callable doesn't respond to `call`.
    def decryption(callable = nil, &block)
      @decryption = resolve_callable(:decryption, callable, &block)
      @encryptor = nil
    end

    # Sets the encryption key. Payloads are encrypted with
    # `ActiveSupport::MessageEncryptor` and AES-256-GCM. This method sets
    # {#encryption} and {#decryption}.
    #
    # @param keys [String, Array<String>, nil] The key, or an array of keys for
    #   key rotation. The first key encrypts data, and all keys are tried for
    #   decryption. If `nil` or empty, encryption is turned off.
    # @return [void]
    # @raise [ArgumentError] If Active Support isn't available.
    def encryption_key=(keys)
      keys = Array(keys).map(&:to_s).reject(&:empty?)
      if keys.empty?
        @encryption = nil
        @decryption = nil
        @encryptor = nil
        return
      end

      unless defined?(ActiveSupport::MessageEncryptor)
        begin
          require "active_support/key_generator"
          require "active_support/message_encryptor"
        rescue LoadError
          raise ArgumentError.new("ActiveSupport::MessageEncryptor is required for encryption_key")
        end
      end

      key_length = ActiveSupport::MessageEncryptor.key_len
      key_generator = lambda do |key|
        ActiveSupport::KeyGenerator.new(key).generate_key(SALT, key_length)
      end

      encryptor = ActiveSupport::MessageEncryptor.new(key_generator.call(keys.first), cipher: "aes-256-gcm")
      keys[1..].each { |key| encryptor.rotate(key_generator.call(key)) }

      encryption { |data| encryptor.encrypt_and_sign(data) }
      decryption { |data| encryptor.decrypt_and_verify(data) }
      @encryptor = nil
    end

    # Returns the encryptor for serialized payloads. If encryption isn't set,
    # the encryptor returns data unchanged.
    #
    # @return [Encryptor] The encryptor.
    def encryptor
      @encryptor ||= Encryptor.new(encryption: @encryption, decryption: @decryption)
    end

    # Registers a named secret. Requests refer to the secret with
    # {PatientHttp.secret}, so the value isn't stored in the job queue.
    #
    # Give the value directly or as a block. The block runs with the secret
    # name each time the secret is resolved. Use a block to read a value when
    # it's needed, for example from the environment.
    #
    # @param name [String, Symbol] The secret name.
    # @param value [Object, nil] The secret value. Omit it when you give a block.
    # @yield [name] Returns the secret value. Omit it when you give a value.
    # @raise [ArgumentError] If you give both a value and a block, or neither.
    # @return [void]
    def register_secret(name, value = nil, &block)
      if value.nil? && block.nil?
        raise ArgumentError.new("register_secret requires a value or a block")
      end

      if !value.nil? && block
        raise ArgumentError.new("register_secret accepts either a value or a block, not both")
      end

      @mutex.synchronize do
        @secrets[name.to_s] = block || value
        @secret_manager = SecretManager.new(secrets: @secrets.dup)
      end
    end

    # Registers a named preprocessor. A preprocessor changes a request
    # immediately before it's sent, for example to sign it.
    #
    # The preprocessor receives an {OutgoingRequest}. At that time, secret
    # references are resolved, and the `x-request-id` and default `user-agent`
    # headers are set. The preprocessor can change the headers and add query
    # parameters.
    #
    # Requests refer to a preprocessor by name. The callable, and any
    # credentials that it uses, stay in the processor and aren't serialized.
    #
    # @param name [String, Symbol] The preprocessor name.
    # @param callable [#call, nil] An object that takes the outgoing request.
    #   Omit it when you give a block.
    # @yield [outgoing_request] Changes the outgoing request. Omit it when you
    #   give a callable.
    # @yieldparam outgoing_request [OutgoingRequest] The request to change.
    # @raise [ArgumentError] If you give both a callable and a block, or neither,
    #   or if the preprocessor doesn't take exactly one argument.
    # @return [void]
    def register_preprocessor(name, callable = nil, &block)
      preprocessor = resolve_callable(:preprocessor, callable, &block)
      raise ArgumentError.new("register_preprocessor requires a callable or a block") if preprocessor.nil?

      validate_preprocessor_parameters!(preprocessor)

      @mutex.synchronize do
        @preprocessors = @preprocessors.merge(name.to_s => preprocessor)
      end
    end

    # Returns a registered preprocessor.
    #
    # @param name [String, Symbol] The preprocessor name.
    # @return [#call, nil] The preprocessor, or `nil` if it isn't registered.
    def preprocessor(name)
      @preprocessors[name.to_s]
    end

    # Registers a payload store for large payloads. A serialized payload larger
    # than {#payload_store_threshold} goes to the store instead of the job
    # queue.
    #
    # References to the stored data include the store name. If you change the
    # name, existing references become invalid.
    #
    # To move to a new store, register both. The last store registered is used
    # for new writes. The other stores remain available for reads.
    #
    # @param name [Symbol, String] The unique name for the store.
    # @param adapter [Symbol, String] The adapter: `:file`, `:redis`, `:s3`,
    #   `:active_record`, or the name of a custom adapter.
    # @param options [Hash] The options for the adapter.
    # @return [void]
    # @raise [ArgumentError] If the adapter isn't registered.
    def register_payload_store(name, adapter:, **options)
      name = name.to_sym
      adapter = adapter.to_sym

      # Trigger autoload for common adapters
      ensure_adapter_loaded(adapter)

      unless PayloadStore::Base.lookup(adapter)
        raise ArgumentError, "Unknown payload store adapter: #{adapter.inspect}. " \
          "Available adapters: #{PayloadStore::Base.registered_adapters.inspect}"
      end

      store = PayloadStore::Base.create(adapter, **options)

      @mutex.synchronize do
        @payload_stores = @payload_stores.merge(name => store)
        @default_payload_store_name = name
      end
    end

    # Returns a registered payload store.
    #
    # @param name [Symbol, String, nil] The store name. If `nil`, the default store
    #   is returned.
    # @return [PayloadStore::Base, nil] The store, or `nil` if it isn't
    #   registered.
    def payload_store(name = nil)
      if name.nil?
        return nil unless @default_payload_store_name

        @payload_stores[@default_payload_store_name]
      else
        @payload_stores[name.to_sym]
      end
    end

    # Returns the name of the default payload store, which is the store for new
    # writes.
    #
    # @return [Symbol, nil] The store name, or `nil` if no store is registered.
    attr_reader :default_payload_store_name

    # Returns all registered payload stores.
    #
    # @return [Hash{Symbol => PayloadStore::Base}] A copy of the stores, keyed by
    #   name.
    def payload_stores
      @payload_stores.dup
    end

    # Returns the configuration as a hash for inspection.
    #
    # @return [Hash{String => Object}] The option values, keyed by option name.
    def to_h
      {
        "max_connections" => max_connections,
        "request_timeout" => request_timeout,
        "shutdown_timeout" => shutdown_timeout,
        "logger" => logger,
        "max_response_size" => max_response_size,
        "user_agent" => user_agent,
        "raise_error_responses" => raise_error_responses,
        "max_redirects" => max_redirects,
        "follow_method_changing_redirects" => follow_method_changing_redirects,
        "redirect_strip_headers" => redirect_strip_headers,
        "connection_pool_size" => connection_pool_size,
        "connection_timeout" => connection_timeout,
        "tcp_keepalive" => tcp_keepalive,
        "tcp_user_timeout" => tcp_user_timeout,
        "proxy_url" => proxy_url,
        "retries" => retries,
        "protocol" => protocol,
        "max_connections_per_host" => max_connections_per_host,
        "completion_threads" => completion_threads,
        "completion_retries" => completion_retries,
        "payload_stores" => payload_stores.keys,
        "default_payload_store" => default_payload_store_name,
        "payload_store_threshold" => payload_store_threshold,
        "secrets" => @mutex.synchronize { @secrets.keys },
        "preprocessors" => @mutex.synchronize { @preprocessors.keys }
      }
    end

    private

    def resolve_callable(name, callable = nil, &block)
      if callable && block
        raise ArgumentError, "#{name} accepts either a callable argument or a block, not both"
      end

      if callable && !callable.respond_to?(:call)
        raise ArgumentError, "#{name} callable must respond to #call"
      end

      callable || block
    end

    # Validates that a preprocessor can be called with one positional argument.
    def validate_preprocessor_parameters!(preprocessor)
      method_obj = preprocessor.is_a?(Proc) ? preprocessor : preprocessor.method(:call)
      parameters = method_obj.parameters

      positional = parameters.count { |type, _| %i[req opt rest].include?(type) }
      required = parameters.count { |type, _| type == :req }
      required_keywords = parameters.count { |type, _| type == :keyreq }

      if positional.zero? || required > 1 || required_keywords.positive?
        raise ArgumentError.new("preprocessor must accept a single argument")
      end
    end

    def validate_positive(attribute, value)
      return if value.is_a?(Numeric) && value > 0

      raise ArgumentError.new("#{attribute} must be a positive number, got: #{value.inspect}")
    end

    def validate_non_negative_integer(attribute, value)
      return if value.is_a?(Integer) && value >= 0

      raise ArgumentError.new("#{attribute} must be a non-negative integer, got: #{value.inspect}")
    end

    def validate_positive_integer(attribute, value)
      return if value.is_a?(Integer) && value > 0

      raise ArgumentError.new("#{attribute} must be a positive integer, got: #{value.inspect}")
    end

    def validate_url(attribute, value)
      uri = URI.parse(value)
      return if uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      raise ArgumentError.new("#{attribute} must be an HTTP or HTTPS URL, got: #{value.inspect}")
    rescue URI::InvalidURIError
      raise ArgumentError.new("#{attribute} must be a valid URL, got: #{value.inspect}")
    end

    # Loads the class of a built-in adapter.
    #
    # @param adapter [Symbol] The adapter name.
    # @return [void]
    def ensure_adapter_loaded(adapter)
      case adapter
      when :file
        PayloadStore::FileStore
      when :redis
        PayloadStore::RedisStore
      when :s3
        PayloadStore::S3Store
      when :active_record
        PayloadStore::ActiveRecordStore
      end
    end
  end
end
