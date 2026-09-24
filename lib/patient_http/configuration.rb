# frozen_string_literal: true

module PatientHttp
  # Configuration for the PatientHttp processor.
  #
  # A configuration holds the options for the HTTP connection pool, such as
  # connection limits, timeouts, and HTTP client settings. It doesn't depend on
  # any job system.
  class Configuration
    # The salt for generating encryption keys. The value is fixed so that all
    # instances generate the same keys. Don't change it.
    SALT = "patient_http_payload_encryption"
    private_constant :SALT

    # @return [Integer] The maximum number of concurrent connections.
    attr_reader :max_connections

    # @return [Integer, nil] The maximum number of connections per host, or `nil` for no limit.
    attr_reader :max_connections_per_host

    # @return [Integer] The number of threads that deliver completed results.
    attr_reader :completion_threads

    # @return [Integer] The number of retries when delivering a completed result fails.
    #   A retry calls the task handler again, so handlers must be idempotent.
    attr_reader :completion_retries

    # @return [Numeric] The default request timeout, in seconds.
    attr_reader :request_timeout

    # @return [Numeric] The graceful shutdown timeout, in seconds.
    attr_reader :shutdown_timeout

    # @return [Integer] The maximum response size, in bytes.
    attr_reader :max_response_size

    # @return [String, nil] The default `User-Agent` header value.
    attr_accessor :user_agent

    # @return [Boolean] Whether non-2xx responses raise {HttpError} by default.
    attr_accessor :raise_error_responses

    # @return [Integer] The maximum number of redirects to follow. `0` disables redirects.
    attr_reader :max_redirects

    # @return [Boolean] Whether to follow a redirect that requires changing the HTTP
    #   method, such as `POST` to `GET` on a 302. If `false`, the redirect response is
    #   returned as the result.
    attr_reader :follow_method_changing_redirects

    # @return [Array<String>] The lowercase names of headers that are always stripped
    #   from redirected requests.
    attr_reader :redirect_strip_headers

    # @return [Integer] The maximum number of hosts to keep connections open for at
    #   one time.
    attr_reader :connection_pool_size

    # @return [Numeric, nil] The time limit for establishing a connection, in seconds.
    #   The limit covers the TCP connect and the TLS handshake. It doesn't limit how
    #   long a request waits for a response. `request_timeout` sets that limit.
    attr_reader :connection_timeout

    # @return [Hash, nil] The TCP keepalive settings for each connection, or `nil` to use
    #   the kernel defaults. The hash has the following keys: `:idle` (seconds before the
    #   first probe), `:interval` (seconds between probes), and `:count` (probes before
    #   the connection is declared dead).
    attr_reader :tcp_keepalive

    # @return [Numeric, nil] The number of seconds that transmitted data can stay
    #   unacknowledged before the kernel aborts the connection (`TCP_USER_TIMEOUT`, Linux
    #   only). A request to a peer that has gone away fails after this time instead of
    #   after the request timeout. The setting has no effect after the server
    #   acknowledges the request.
    attr_reader :tcp_user_timeout

    # @return [String, nil] The HTTP or HTTPS proxy URL. The URL can include credentials.
    attr_reader :proxy_url

    # @return [Integer] The maximum number of attempts for a request that fails before
    #   any response bytes arrive. At least 3 attempts are always allowed.
    attr_reader :retries

    # @return [Symbol, nil] The HTTP protocol to use, either `:http1` or `:http2`. If `nil`,
    #   the client negotiates the protocol with the server and prefers HTTP/2 for HTTPS.
    attr_reader :protocol

    # @return [SecretManager] The secret manager.
    attr_reader :secret_manager

    # Creates a configuration with the specified options.
    #
    # @param max_connections [Integer] The maximum number of concurrent connections.
    # @param request_timeout [Numeric] The default request timeout, in seconds.
    # @param shutdown_timeout [Numeric] The graceful shutdown timeout, in seconds.
    # @param logger [Logger, nil] The logger. Defaults to a logger that writes errors to
    #   standard error.
    # @param max_response_size [Integer] The maximum response size, in bytes.
    # @param user_agent [String, nil] The default `User-Agent` header value.
    # @param raise_error_responses [Boolean] Whether non-2xx responses raise {HttpError}
    #   by default.
    # @param max_redirects [Integer] The maximum number of redirects to follow. `0` disables
    #   redirects.
    # @param follow_method_changing_redirects [Boolean] Whether to follow a redirect that
    #   requires changing the HTTP method, such as `POST` to `GET` on a 301, 302, or 303
    #   response. If `false`, a request whose method would change receives the redirect
    #   response instead.
    # @param redirect_strip_headers [String, Array<String>] Header names to strip from every
    #   redirected request, so sensitive headers are never sent to a redirect target.
    #   Names are case insensitive.
    # @param connection_pool_size [Integer] The maximum number of host clients to pool.
    # @param connection_timeout [Numeric, nil] The time limit for establishing a connection,
    #   in seconds. The limit covers the TCP connect and the TLS handshake.
    # @param tcp_keepalive [Integer, Hash, nil] The TCP keepalive idle time in seconds, or a
    #   hash with the keys `:idle`, `:interval`, and `:count`. `nil` keeps the kernel defaults.
    # @param tcp_user_timeout [Numeric, nil] The number of seconds that transmitted data can
    #   stay unacknowledged before the kernel aborts the connection (Linux only). `nil` keeps
    #   the kernel default.
    # @param proxy_url [String, nil] The HTTP or HTTPS proxy URL. The URL can include
    #   credentials.
    # @param retries [Integer] The maximum number of attempts for a request that fails before
    #   any response bytes arrive. At least 3 attempts are always allowed.
    # @param protocol [Symbol, nil] The HTTP protocol to use, either `:http1` or `:http2`.
    #   `nil` negotiates the protocol with the server.
    # @param encryption_key [String, Array<String>, nil] The key used to encrypt payloads.
    #   See {#encryption_key=}.
    # @param max_connections_per_host [Integer, nil] The maximum number of connections per
    #   host, or `nil` for no limit.
    # @param completion_threads [Integer] The number of threads that deliver completed results.
    # @param completion_retries [Integer] The number of retries when delivering a completed
    #   result fails. A retry calls {TaskHandler#on_complete} or {TaskHandler#on_error} again.
    #   If a handler raises an error after its side effect, the callback is delivered more
    #   than once unless the handler is idempotent. Set this option to `0` to report the
    #   first failure without retrying.
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
      completion_retries: 2
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
    end

    # The logger for pool events. By default, the logger writes errors to standard error.
    #
    # @return [Logger] The logger.
    attr_accessor :logger

    def max_connections=(value)
      validate_positive(:max_connections, value)
      @max_connections = value
    end

    def max_connections_per_host=(value)
      if value.nil?
        @max_connections_per_host = nil
        return
      end

      validate_positive_integer(:max_connections_per_host, value)
      @max_connections_per_host = value
    end

    def completion_threads=(value)
      validate_positive_integer(:completion_threads, value)
      @completion_threads = value
    end

    def completion_retries=(value)
      validate_non_negative_integer(:completion_retries, value)
      @completion_retries = value
    end

    def request_timeout=(value)
      validate_positive(:request_timeout, value)
      @request_timeout = value
    end

    def shutdown_timeout=(value)
      validate_positive(:shutdown_timeout, value)
      @shutdown_timeout = value
    end

    def max_response_size=(value)
      validate_positive(:max_response_size, value)
      @max_response_size = value
    end

    def max_redirects=(value)
      validate_non_negative_integer(:max_redirects, value)
      @max_redirects = value
    end

    def follow_method_changing_redirects=(value)
      unless value == true || value == false
        raise ArgumentError.new("follow_method_changing_redirects must be true or false, got: #{value.inspect}")
      end

      @follow_method_changing_redirects = value
    end

    def redirect_strip_headers=(value)
      @redirect_strip_headers = RedirectHelper.normalize_header_names(value)
    end

    def connection_pool_size=(value)
      validate_positive_integer(:connection_pool_size, value)
      @connection_pool_size = value
    end

    def connection_timeout=(value)
      if value.nil?
        @connection_timeout = nil
        return
      end

      validate_positive(:connection_timeout, value)
      @connection_timeout = value
    end

    # Sets TCP keepalive for pooled connections.
    #
    # @param value [Numeric, Hash, nil] The idle time in seconds before the first probe,
    #   or a hash with the key `:idle` and the optional keys `:interval` (default 10
    #   seconds) and `:count` (default 3 probes). `nil` disables keepalive.
    # @return [void]
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

    # Sets how long transmitted data can stay unacknowledged before the kernel aborts
    # the connection. The setting applies only on platforms that support
    # `TCP_USER_TIMEOUT`.
    #
    # @param value [Numeric, nil] The time in seconds, or `nil` to use the kernel default.
    # @return [void]
    def tcp_user_timeout=(value)
      if value.nil?
        @tcp_user_timeout = nil
        return
      end

      validate_positive(:tcp_user_timeout, value)
      @tcp_user_timeout = value
    end

    def proxy_url=(value)
      if value.nil?
        @proxy_url = nil
        return
      end

      validate_url(:proxy_url, value)
      @proxy_url = value
    end

    def retries=(value)
      validate_non_negative_integer(:retries, value)
      @retries = value
    end

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

    # Sets the callable that encrypts payloads before serialization.
    #
    # @param callable [#call, nil] An object that responds to `call`. It takes data and
    #   returns encrypted data.
    # @yield [data] A block that takes data and returns encrypted data.
    # @raise [ArgumentError] If you provide both a callable and a block, or if the callable
    #   doesn't respond to `call`.
    def encryption(callable = nil, &block)
      @encryption = resolve_callable(:encryption, callable, &block)
      @encryptor = nil
    end

    # Sets the callable that decrypts payloads after deserialization.
    #
    # @param callable [#call, nil] An object that responds to `call`. It takes encrypted
    #   data and returns decrypted data.
    # @yield [data] A block that takes encrypted data and returns decrypted data.
    # @raise [ArgumentError] If you provide both a callable and a block, or if the callable
    #   doesn't respond to `call`.
    def decryption(callable = nil, &block)
      @decryption = resolve_callable(:decryption, callable, &block)
      @encryptor = nil
    end

    # Sets up payload encryption with `ActiveSupport::MessageEncryptor` and AES-256-GCM.
    #
    # The first key encrypts new data. All keys are tried for decryption, so you can
    # rotate keys by adding the new key to the front of the list.
    #
    # @param keys [String, Array<String>, nil] The encryption key or keys. `nil` or an
    #   empty value turns off encryption.
    # @raise [ArgumentError] If `ActiveSupport::MessageEncryptor` isn't available.
    # @return [void]
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

    # Returns an {Encryptor} built from the configured callables. If encryption and
    # decryption aren't set, the encryptor returns data unchanged.
    #
    # @return [Encryptor] The encryptor.
    def encryptor
      @encryptor ||= Encryptor.new(encryption: @encryption, decryption: @decryption)
    end

    # Registers a named secret. Requests reference the secret by name with
    # {PatientHttp.secret}.
    #
    # You can provide the value directly or as a block. The block is called with the
    # secret name each time the secret is resolved. Use a block for values that you
    # want to read on demand, such as values from the environment.
    #
    # @param name [String, Symbol] The secret name.
    # @param value [Object, nil] The secret value. Omit this argument if you provide a block.
    # @yield [name] A block that returns the secret value. Omit the block if you provide a value.
    # @raise [ArgumentError] If you provide neither a value nor a block, or both.
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

    # Registers a named preprocessor. A request that references the preprocessor is
    # modified by it right before it's sent. For example, a preprocessor can sign
    # requests.
    #
    # Provide the preprocessor as a callable or a block that takes one argument. When
    # a request that references the preprocessor is sent, the preprocessor is called
    # with an {OutgoingRequest}. At that point, secret references are resolved and the
    # `x-request-id` and default `user-agent` headers are set. The preprocessor can
    # change the request headers and append query parameters.
    #
    # Requests reference preprocessors by name only. The callable and any credentials
    # it uses stay on the processor side and are never serialized.
    #
    # @param name [String, Symbol] The preprocessor name.
    # @param callable [#call, nil] An object that is called with the outgoing request.
    #   Omit this argument if you provide a block.
    # @yield [outgoing_request] A block that is called with the outgoing request. Omit the
    #   block if you provide a callable.
    # @raise [ArgumentError] If you provide neither a callable nor a block, or both, or if
    #   the preprocessor can't be called with one argument.
    # @return [void]
    def register_preprocessor(name, callable = nil, &block)
      preprocessor = resolve_callable(:preprocessor, callable, &block)
      raise ArgumentError.new("register_preprocessor requires a callable or a block") if preprocessor.nil?

      validate_preprocessor_parameters!(preprocessor)

      @mutex.synchronize do
        @preprocessors = @preprocessors.merge(name.to_s => preprocessor)
      end
    end

    # Returns a registered preprocessor by name.
    #
    # @param name [String, Symbol] The preprocessor name.
    # @return [#call, nil] The preprocessor, or `nil` if it isn't registered.
    def preprocessor(name)
      @preprocessors[name.to_s]
    end

    # Registers a payload store for external storage of large payloads.
    #
    # Serialized references to stored data include the store name. If you change the
    # name, existing references become invalid.
    #
    # To migrate between stores, register more than one. The last store registered
    # becomes the default for new writes. References to the other registered stores
    # stay valid for reads.
    #
    # @param name [Symbol, String] A unique name for this store.
    # @param adapter [Symbol, String] The adapter type, such as `:file`, `:redis`, `:s3`,
    #   or `:active_record`.
    # @param options [Hash] The options to pass to the adapter constructor.
    # @return [void]
    # @raise [ArgumentError] If the adapter is not registered.
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

    # Returns a registered payload store by name.
    #
    # @param name [Symbol, String, nil] The store name. If `nil`, returns the default store.
    # @return [PayloadStore::Base, nil] The store, or `nil` if it isn't found.
    def payload_store(name = nil)
      if name.nil?
        return nil unless @default_payload_store_name

        @payload_stores[@default_payload_store_name]
      else
        @payload_stores[name.to_sym]
      end
    end

    # The name of the default payload store.
    #
    # @return [Symbol, nil] The default store name, or `nil` if no store is registered.
    attr_reader :default_payload_store_name

    # Returns all registered payload stores.
    #
    # @return [Hash{Symbol => PayloadStore::Base}] A copy of the registered stores.
    def payload_stores
      @payload_stores.dup
    end

    # Converts the configuration to a hash for inspection.
    #
    # @return [Hash] A hash with string keys.
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

    # Loads the adapter class through autoload.
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
