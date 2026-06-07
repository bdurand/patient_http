# frozen_string_literal: true

module PatientHttp
  # Configuration for the PatientHttp processor.
  #
  # This class holds all configuration options for the HTTP connection pool,
  # including connection limits, timeouts, and other HTTP client settings.
  # It has no dependencies on any job system.
  class Configuration
    # Salt used for generating encryption keys. This is a fixed value to ensure
    # consistent key generation across instances and must never be changed.
    SALT = "patient_http_payload_encryption"
    private_constant :SALT

    # @return [Integer] Maximum number of concurrent connections
    attr_reader :max_connections

    # @return [Numeric] Default request timeout in seconds
    attr_reader :request_timeout

    # @return [Numeric] Graceful shutdown timeout in seconds
    attr_reader :shutdown_timeout

    # @return [Integer] Maximum response size in bytes
    attr_reader :max_response_size

    # @return [String, nil] Default User-Agent header value
    attr_accessor :user_agent

    # @return [Boolean] Whether to raise HttpError for non-2xx responses by default
    attr_accessor :raise_error_responses

    # @return [Integer] Maximum number of redirects to follow (0 disables redirects)
    attr_reader :max_redirects

    # @return [Integer] This is the maximum number of hosts for which connections
    #   will be kept alive for at one time.
    attr_reader :connection_pool_size

    # @return [Numeric, nil] Connection timeout in seconds
    attr_reader :connection_timeout

    # @return [String, nil] HTTP/HTTPS proxy URL (supports authentication)
    attr_reader :proxy_url

    # @return [Integer] Number of retries for failed requests
    attr_reader :retries

    # Initializes a new Configuration with the specified options.
    #
    # @param max_connections [Integer] Maximum number of concurrent connections
    # @param request_timeout [Numeric] Default request timeout in seconds
    # @param shutdown_timeout [Numeric] Graceful shutdown timeout in seconds
    # @param logger [Logger, nil] Logger instance to use (defaults to stdout)
    # @param max_response_size [Integer] Maximum response size in bytes
    # @param user_agent [String, nil] Default User-Agent header value
    # @param raise_error_responses [Boolean] Whether to raise HttpError for non-2xx responses by default
    # @param max_redirects [Integer] Maximum number of redirects to follow (0 disables redirects)
    # @param connection_pool_size [Integer] Maximum number of host clients to pool
    # @param connection_timeout [Numeric, nil] Connection timeout in seconds
    # @param proxy_url [String, nil] HTTP/HTTPS proxy URL (supports authentication)
    # @param retries [Integer] Number of retries for failed requests
    def initialize(
      max_connections: 256,
      request_timeout: 60,
      shutdown_timeout: 30,
      logger: nil,
      max_response_size: 1024 * 1024,
      user_agent: "PatientHttp",
      raise_error_responses: false,
      max_redirects: 5,
      connection_pool_size: 100,
      connection_timeout: nil,
      proxy_url: nil,
      retries: 3,
      encryption_key: nil
    )
      @mutex = Mutex.new

      # Initialize payload store configuration
      @payload_stores = {}
      @default_payload_store_name = nil

      # Initialize secret configuration
      @secrets = {}
      @secret_manager = nil

      @encryptor = nil

      self.max_connections = max_connections
      self.request_timeout = request_timeout
      self.shutdown_timeout = shutdown_timeout
      self.logger = logger || Logger.new($stderr, level: Logger::ERROR)
      self.max_response_size = max_response_size
      self.user_agent = user_agent
      self.raise_error_responses = raise_error_responses
      self.max_redirects = max_redirects
      self.connection_pool_size = connection_pool_size
      self.connection_timeout = connection_timeout
      self.proxy_url = proxy_url
      self.retries = retries
      self.encryption_key = encryption_key
    end

    # Get the logger to use to report pool events. Default is to log errors to STDERR.
    # @return [Logger] the logger instance
    attr_accessor :logger

    def max_connections=(value)
      validate_positive(:max_connections, value)
      @max_connections = value
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

    # Set the encryption callable for encrypting payloads before serialization.
    #
    # @param callable [#call, nil] An object that responds to #call, taking data and returning encrypted data
    # @yield [data] A block that takes data and returns encrypted data
    # @raise [ArgumentError] If both callable and block are provided, or if callable doesn't respond to #call
    def encryption(callable = nil, &block)
      @encryption = resolve_callable(:encryption, callable, &block)
      @encryptor = nil
    end

    # Set the decryption callable for decrypting payloads after deserialization.
    #
    # @param callable [#call, nil] An object that responds to #call, taking data and returning decrypted data
    # @yield [data] A block that takes data and returns decrypted data
    # @raise [ArgumentError] If both callable and block are provided, or if callable doesn't respond to #call
    def decryption(callable = nil, &block)
      @decryption = resolve_callable(:decryption, callable, &block)
      @encryptor = nil
    end

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

    # Return an Encryptor instance. If encryption and decryption are not set, then
    # this will be an empty Encryptor that returns data unchanged.
    #
    # @return [Encryptor] the encryptor instance
    def encryptor
      @encryptor ||= Encryptor.new(encryption: @encryption, decryption: @decryption)
    end

    # Register a named secret whose value can be referenced indirectly when building
    # requests via {PatientHttp.secret}.
    #
    # The value can be provided directly or as a block (callable). A block is invoked
    # lazily with the secret name each time the secret is resolved, which is useful for
    # values that should be read on demand (for example, from the environment).
    #
    # @param name [String, Symbol] the secret name
    # @param value [Object, nil] the secret value (omit when providing a block)
    # @yield [name] a block that returns the secret value (omit when providing a value)
    # @raise [ArgumentError] if neither or both of value and block are provided
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
        @secret_manager = nil
      end
    end

    # Return a {SecretManager} built from the registered secrets.
    #
    # @return [SecretManager] the secret manager instance
    def secret_manager
      @mutex.synchronize do
        @secret_manager ||= SecretManager.new(secrets: @secrets.dup)
      end
    end

    # Register a payload store for external storage of large payloads.
    #
    # The name is included in the serialized references to the stored data.
    # Changing it will cause any existing reference to become invalid.
    #
    # Multiple stores can be registered for migration purposes. The last
    # store registered becomes the default used for new writes. References
    # to other registered stores remain valid for reading.
    #
    # @param name [Symbol, String] Unique name for this store registration
    # @param adapter [Symbol, String] The adapter type (:file, :redis, :s3, etc.)
    # @param options [Hash] Options passed to the adapter constructor
    # @return [void]
    # @raise [ArgumentError] If the adapter is not registered
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
        @payload_stores[name] = store
        @default_payload_store_name = name
      end
    end

    # Get a registered payload store by name.
    #
    # @param name [Symbol, String, nil] Store name. If nil, returns the default store.
    # @return [PayloadStore::Base, nil] The store instance or nil if not found
    def payload_store(name = nil)
      @mutex.synchronize do
        if name.nil?
          return nil unless @default_payload_store_name

          @payload_stores[@default_payload_store_name]
        else
          @payload_stores[name.to_sym]
        end
      end
    end

    # Get the name of the default payload store.
    #
    # @return [Symbol, nil] The default store name or nil if none registered
    def default_payload_store_name
      @mutex.synchronize do
        @default_payload_store_name
      end
    end

    # Get all registered payload stores.
    #
    # @return [Hash{Symbol => PayloadStore::Base}] Copy of registered stores
    def payload_stores
      @mutex.synchronize do
        @payload_stores.dup
      end
    end

    # Convert to hash for inspection
    # @return [Hash] hash representation with string keys
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
        "connection_pool_size" => connection_pool_size,
        "connection_timeout" => connection_timeout,
        "proxy_url" => proxy_url,
        "retries" => retries,
        "payload_stores" => payload_stores.keys,
        "default_payload_store" => default_payload_store_name,
        "secrets" => @mutex.synchronize { @secrets.keys }
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

    # Ensure adapter class is loaded (triggers autoload).
    #
    # @param adapter [Symbol] The adapter name
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
