# frozen_string_literal: true

module PatientHttp
  # Configuration for the PatientHttp processor.
  #
  # This class holds all the configuration options for the HTTP connection pool,
  # including connection limits, timeouts, and other HTTP client settings. It has no
  # dependencies on any job system.
  class Configuration
    # Salt used to generate encryption keys. The value is fixed so that every instance
    # generates the same keys. Never change it.
    SALT = "patient_http_payload_encryption"
    private_constant :SALT

    # @return [Integer] The maximum number of concurrent connections.
    attr_reader :max_connections

    # @return [Integer, nil] The maximum number of connections per host, or nil for an
    #   unlimited number.
    attr_reader :max_connections_per_host

    # @return [Integer] The number of threads that deliver completed results.
    attr_reader :completion_threads

    # @return [Integer] The number of retries when the delivery of a completed result
    #   fails. A retry calls the task handler again, so handlers must be idempotent.
    attr_reader :completion_retries

    # @return [Numeric] The default request timeout, in seconds.
    attr_reader :request_timeout

    # @return [Numeric] The graceful shutdown timeout, in seconds.
    attr_reader :shutdown_timeout

    # @return [Integer] The maximum response size, in bytes.
    attr_reader :max_response_size

    # @return [String, nil] The default User-Agent header value.
    attr_accessor :user_agent

    # @return [Boolean] Whether to raise an {HttpError} for non-2xx responses by
    #   default.
    attr_accessor :raise_error_responses

    # @return [Integer] The maximum number of redirects to follow. A value of 0
    #   disables redirects.
    attr_reader :max_redirects

    # @return [Boolean] Whether to follow a redirect that requires a change of the
    #   HTTP method, such as POST to GET on a 302. When false, the redirect response
    #   is returned as the result instead.
    attr_reader :follow_method_changing_redirects

    # @return [Array<String>] The lowercase header names that are always stripped from
    #   redirected requests.
    attr_reader :redirect_strip_headers

    # @return [Integer] The maximum number of hosts to keep connections alive for at
    #   one time.
    attr_reader :connection_pool_size

    # @return [Numeric, nil] The connection timeout, in seconds.
    attr_reader :connection_timeout

    # @return [String, nil] The HTTP or HTTPS proxy URL. Authentication is supported.
    attr_reader :proxy_url

    # @return [Integer] The number of retries for a failed request.
    attr_reader :retries

    # @return [Symbol, nil] The HTTP protocol to use, either `:http1` or `:http2`.
    #   When nil, the protocol is negotiated with the server, and HTTP/2 is preferred
    #   for HTTPS.
    attr_reader :protocol

    # @return [SecretManager] The secret manager.
    attr_reader :secret_manager

    # Initializes a new Configuration with the given options.
    #
    # @param max_connections [Integer] The maximum number of concurrent connections.
    # @param request_timeout [Numeric] The default request timeout, in seconds.
    # @param shutdown_timeout [Numeric] The graceful shutdown timeout, in seconds.
    # @param logger [Logger, nil] The logger to use. Defaults to a logger that writes
    #   errors to STDERR.
    # @param max_response_size [Integer] The maximum response size, in bytes.
    # @param user_agent [String, nil] The default User-Agent header value.
    # @param raise_error_responses [Boolean] Whether to raise an {HttpError} for
    #   non-2xx responses by default.
    # @param max_redirects [Integer] The maximum number of redirects to follow. A
    #   value of 0 disables redirects.
    # @param follow_method_changing_redirects [Boolean] Whether to follow a redirect
    #   that requires a change of the HTTP method, such as POST to GET on a 301, 302,
    #   or 303 response. When false, a request whose method would change does not
    #   follow the redirect and receives the redirect response.
    # @param redirect_strip_headers [String, Array<String>] Header names (case
    #   insensitive) that are always stripped from redirected requests, so that
    #   sensitive headers are never sent to a redirect target.
    # @param connection_pool_size [Integer] The maximum number of host clients to
    #   keep in the pool.
    # @param connection_timeout [Numeric, nil] The connection timeout, in seconds.
    # @param proxy_url [String, nil] The HTTP or HTTPS proxy URL. Authentication is
    #   supported.
    # @param retries [Integer] The number of retries for a failed request.
    # @param protocol [Symbol, nil] The HTTP protocol to use, either `:http1` or
    #   `:http2`. Use nil to negotiate the protocol with the server.
    # @param max_connections_per_host [Integer, nil] The maximum number of connections
    #   per host, or nil for an unlimited number.
    # @param completion_threads [Integer] The number of threads that deliver completed
    #   results.
    # @param completion_retries [Integer] The number of retries when the delivery of a
    #   completed result fails. A retry calls {TaskHandler#on_complete} or
    #   {TaskHandler#on_error} again, so a handler that raises an error after its side
    #   effect delivers the callback more than once unless the handler is idempotent.
    #   Set this to 0 to report the first failure without retrying.
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
      self.proxy_url = proxy_url
      self.retries = retries
      self.protocol = protocol
      self.encryption_key = encryption_key
      self.max_connections_per_host = max_connections_per_host
      self.completion_threads = completion_threads
      self.completion_retries = completion_retries
    end

    # Returns the logger that reports pool events. By default, errors are logged to
    # STDERR.
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
    # @param callable [#call, nil] An object that responds to `call`, takes data, and
    #   returns encrypted data.
    # @yield [data] A block that takes data and returns encrypted data.
    # @return [void]
    # @raise [ArgumentError] If both a callable and a block are provided, or if the
    #   callable does not respond to `call`.
    def encryption(callable = nil, &block)
      @encryption = resolve_callable(:encryption, callable, &block)
      @encryptor = nil
    end

    # Sets the callable that decrypts payloads after deserialization.
    #
    # @param callable [#call, nil] An object that responds to `call`, takes data, and
    #   returns decrypted data.
    # @yield [data] A block that takes data and returns decrypted data.
    # @return [void]
    # @raise [ArgumentError] If both a callable and a block are provided, or if the
    #   callable does not respond to `call`.
    def decryption(callable = nil, &block)
      @decryption = resolve_callable(:decryption, callable, &block)
      @encryptor = nil
    end

    # Sets the encryption key, or the keys, that encrypt and decrypt payloads with
    # `ActiveSupport::MessageEncryptor` and AES-256-GCM.
    #
    # Pass an array to rotate the keys. The first key encrypts new data, and every key
    # is tried for decryption. Pass nil or an empty array to turn the encryption off.
    #
    # @param keys [String, Array<String>, nil] The encryption key or keys.
    # @return [void]
    # @raise [ArgumentError] If ActiveSupport::MessageEncryptor is not available.
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

    # Returns an {Encryptor}. If no encryption and decryption callables are set, the
    # encryptor returns the data unchanged.
    #
    # @return [Encryptor] The encryptor.
    def encryptor
      @encryptor ||= Encryptor.new(encryption: @encryption, decryption: @decryption)
    end

    # Registers a named secret whose value you can reference indirectly with
    # {PatientHttp.secret} when you build a request.
    #
    # Provide the value directly or as a block. A block runs with the secret name each
    # time the secret is resolved, which is useful for values that must be read on
    # demand, for example from the environment.
    #
    # @param name [String, Symbol] The secret name.
    # @param value [Object, nil] The secret value. Omit this when you provide a block.
    # @yield [name] A block that returns the secret value. Omit this when you provide
    #   a value.
    # @return [void]
    # @raise [ArgumentError] If neither or both of the value and the block are
    #   provided.
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

    # Registers a named preprocessor that you can attach to a request to modify the
    # request just before it is sent, for example to sign it.
    #
    # Provide the preprocessor as a callable or as a block that takes a single
    # argument. When a request that references the preprocessor is sent, the
    # preprocessor runs with an {OutgoingRequest} after the secret references are
    # resolved and after the x-request-id and default user-agent headers are set. The
    # preprocessor can change the request headers and append query parameters.
    #
    # A request references a preprocessor by name only, so the callable, and any
    # credentials that it uses, stays on the processor side and is never serialized.
    #
    # @param name [String, Symbol] The preprocessor name.
    # @param callable [#call, nil] An object that runs with the outgoing request. Omit
    #   this when you provide a block.
    # @yield [outgoing_request] A block that runs with the outgoing request. Omit this
    #   when you provide a callable.
    # @return [void]
    # @raise [ArgumentError] If neither or both of the callable and the block are
    #   provided, or if the preprocessor cannot be called with a single argument.
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
    # @return [#call, nil] The preprocessor, or nil if the name is not registered.
    def preprocessor(name)
      @preprocessors[name.to_s]
    end

    # Registers a payload store for the external storage of large payloads.
    #
    # The name is included in the serialized references to the stored data. If you
    # change the name, every existing reference becomes invalid.
    #
    # You can register more than one store to migrate between stores. The store that
    # you register last becomes the default for new writes. References to the other
    # registered stores stay valid for reading.
    #
    # @param name [Symbol, String] A unique name for this store registration.
    # @param adapter [Symbol, String] The adapter type, such as `:file`, `:redis`, or
    #   `:s3`.
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

    # Returns a registered payload store.
    #
    # @param name [Symbol, String, nil] The store name. If nil, the default store is
    #   returned.
    # @return [PayloadStore::Base, nil] The store, or nil if the name is not found.
    def payload_store(name = nil)
      if name.nil?
        return nil unless @default_payload_store_name

        @payload_stores[@default_payload_store_name]
      else
        @payload_stores[name.to_sym]
      end
    end

    # Returns the name of the default payload store.
    #
    # @return [Symbol, nil] The default store name, or nil if no store is registered.
    attr_reader :default_payload_store_name

    # Returns all registered payload stores.
    #
    # @return [Hash{Symbol => PayloadStore::Base}] A copy of the registered stores.
    def payload_stores
      @payload_stores.dup
    end

    # Converts the configuration to a hash for inspection.
    #
    # @return [Hash] The hash representation, with string keys.
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

    # Validates that a preprocessor can be called with a single positional argument.
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

    # Makes sure that the adapter class is loaded, which triggers its autoload.
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
