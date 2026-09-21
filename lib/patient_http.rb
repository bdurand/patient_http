# frozen_string_literal: true

require "async"
require "async/http"
require "concurrent"
require "monitor"
require "json"
require "uri"
require "zlib"
require "time"
require "socket"
require "securerandom"
require "logger"

# Generic async HTTP connection pool for Ruby applications.
#
# This module provides:
#
# - Async HTTP request processing that uses Ruby's Fiber scheduler
# - Connection pooling with HTTP/2 support
# - Configurable timeouts, retries, and proxy support
# - Error handling with typed errors
#
# Use this module on its own, or integrate it with a job system such as
# Sidekiq through an adapter.
module PatientHttp
  # Raised when a request is enqueued while the processor is not running.
  class NotRunningError < StandardError; end

  # Raised when a request is enqueued while the processor is at maximum capacity.
  class MaxCapacityError < StandardError; end

  # Raised when a response body is larger than the configured maximum size.
  class ResponseTooLargeError < StandardError; end

  # Raised when a request names a processor that is not configured. Handlers that
  # support named processors raise this error at enqueue time. The executing side
  # raises it for a job that names an unconfigured processor, so that the job lands
  # in the job system's retry mechanism instead of being dropped.
  class UnknownProcessorError < StandardError; end

  # HTTP redirect status codes that are followed when a Location header is present.
  # A 300 response is followed only when the server names a preferred choice in Location.
  FOLLOWABLE_REDIRECT_STATUSES = [300, 301, 302, 303, 307, 308].freeze

  # The version of the gem.
  # The version of the gem.
  VERSION = File.read(File.join(__dir__, "../VERSION")).strip

  # Autoload utility modules
  autoload :ClassHelper, File.join(__dir__, "patient_http/class_helper")
  autoload :TimeHelper, File.join(__dir__, "patient_http/time_helper")

  # Autoload all components
  autoload :CallbackArgs, File.join(__dir__, "patient_http/callback_args")
  autoload :CallbackValidator, File.join(__dir__, "patient_http/callback_validator")
  autoload :Client, File.join(__dir__, "patient_http/client")
  autoload :ClientError, File.join(__dir__, "patient_http/http_error")
  autoload :ClientPool, File.join(__dir__, "patient_http/client_pool")
  autoload :CompletionExecutor, File.join(__dir__, "patient_http/completion_executor")
  autoload :Configuration, File.join(__dir__, "patient_http/configuration")
  autoload :Encryptor, File.join(__dir__, "patient_http/encryptor")
  autoload :Error, File.join(__dir__, "patient_http/error")
  autoload :ExternalStorage, File.join(__dir__, "patient_http/external_storage")
  autoload :HttpError, File.join(__dir__, "patient_http/http_error")
  autoload :HttpHeaders, File.join(__dir__, "patient_http/http_headers")
  autoload :InlineTaskHandler, File.join(__dir__, "patient_http/inline_task_handler")
  autoload :LifecycleManager, File.join(__dir__, "patient_http/lifecycle_manager")
  autoload :OutgoingRequest, File.join(__dir__, "patient_http/outgoing_request")
  autoload :Payload, File.join(__dir__, "patient_http/payload")
  autoload :PayloadStore, File.join(__dir__, "patient_http/payload_store")
  autoload :Processor, File.join(__dir__, "patient_http/processor")
  autoload :ProcessorObserver, File.join(__dir__, "patient_http/processor_observer")
  autoload :RecursiveRedirectError, File.join(__dir__, "patient_http/redirect_error")
  autoload :RedirectError, File.join(__dir__, "patient_http/redirect_error")
  autoload :RedirectHelper, File.join(__dir__, "patient_http/redirect_helper")
  autoload :Request, File.join(__dir__, "patient_http/request")
  autoload :RequestError, File.join(__dir__, "patient_http/request_error")
  autoload :RequestHelper, File.join(__dir__, "patient_http/request_helper")
  autoload :RequestPreparer, File.join(__dir__, "patient_http/request_preparer")
  autoload :RequestTask, File.join(__dir__, "patient_http/request_task")
  autoload :RequestTemplate, File.join(__dir__, "patient_http/request_template")
  autoload :Response, File.join(__dir__, "patient_http/response")
  autoload :ResponseReader, File.join(__dir__, "patient_http/response_reader")
  autoload :SecretManager, File.join(__dir__, "patient_http/secret_manager")
  autoload :SecretReference, File.join(__dir__, "patient_http/secret_reference")
  autoload :ServerError, File.join(__dir__, "patient_http/http_error")
  autoload :SynchronousExecutor, File.join(__dir__, "patient_http/synchronous_executor")
  autoload :TaskHandler, File.join(__dir__, "patient_http/task_handler")
  autoload :TooManyRedirectsError, File.join(__dir__, "patient_http/redirect_error")

  @testing = %w[RAILS_ENV RACK_ENV APP_ENV].any? { |var| ENV[var] == "test" }
  @handler = nil
  @handler_mutex = Monitor.new
  @inline_handler = nil
  @default_configuration = nil
  @inline_configuration = nil
  @module_secrets = {}
  @config_mutex = Monitor.new

  class << self
    # Checks whether the library is running in testing mode.
    #
    # @return [Boolean] Whether testing mode is enabled.
    # @api private
    def testing?
      @testing
    end

    # Sets testing mode.
    #
    # @param value [Boolean] Whether to enable testing mode.
    # @return [Boolean] The value that was set.
    # @api private
    def testing=(value)
      @testing = !!value
    end

    # Registers a request handler that processes each request. The handler must be a
    # callable object (one that responds to `call`) or a block.
    #
    # The handler receives the keyword arguments `request`, `callback`,
    # `callback_args`, and `raise_error_responses`, and must return the request ID of
    # the enqueued request.
    #
    # @param callable [#call, nil] A callable object that handles requests.
    # @yield [request, callback, callback_args, raise_error_responses] A block to use
    #   as the request handler.
    # @return [#call] The registered handler.
    # @raise [ArgumentError] If neither a callable nor a block is provided, or if both
    #   are provided.
    # @raise [ArgumentError] If the callable does not respond to `call`.
    # @raise [ArgumentError] If the handler does not accept the required keyword
    #   arguments.
    def register_handler(callable = nil, &block)
      raise ArgumentError.new("Must provide a callable object or a block") unless callable || block_given?
      raise ArgumentError.new("Cannot provide both a callable object and a block") if callable && block_given?

      handler = callable || block
      raise ArgumentError.new("Handler must be a callable object or a block") unless handler.respond_to?(:call)

      validate_handler_parameters!(handler)

      @handler_mutex.synchronize { @handler = handler }
    end

    # Registers a request handler and raises an error if one is already registered.
    #
    # This is a safer alternative to {.register_handler} because it prevents
    # accidental double registration.
    #
    # @param callable [#call, nil] A callable object that handles requests.
    # @yield [request, callback, callback_args, raise_error_responses] A block to use
    #   as the request handler.
    # @return [#call] The registered handler.
    # @raise [RuntimeError] If a handler is already registered.
    # @raise [ArgumentError] If neither a callable nor a block is provided, or if both
    #   are provided.
    # @raise [ArgumentError] If the callable does not respond to `call`.
    # @raise [ArgumentError] If the handler does not accept the required keyword
    #   arguments.
    def register_handler!(callable = nil, &block)
      @handler_mutex.synchronize do
        if @handler
          raise "A PatientHttp handler is already registered. Unregister the existing handler before registering a new one."
        end

        register_handler(callable, &block)
      end
    end

    # Unregisters the current request handler.
    #
    # @param handler [#call, nil] A handler to unregister only if it is the current
    #   handler. When nil, the current handler is always unregistered.
    # @return [void]
    def unregister_handler(handler = nil)
      @handler_mutex.synchronize do
        @handler = nil if @handler == handler || handler.nil?
      end
    end

    # Registers a request handler that runs requests inline (synchronously and in
    # process) instead of dispatching them to a job system.
    #
    # Use this in consoles, tests, and development environments where no job system
    # integration gem is configured. Each request runs through {SynchronousExecutor},
    # and the callback runs on the calling thread before the handler returns.
    #
    # @param config [Configuration, nil] The configuration to run requests against.
    #   Defaults to {.default_configuration}, or to a lazily created configuration
    #   that includes any secrets registered with {.register_secret}.
    # @return [void]
    def inline!(config: nil)
      handler = lambda do |request:, callback:, callback_args: nil, raise_error_responses: nil|
        execute_inline(
          request: request,
          callback: callback,
          callback_args: callback_args,
          raise_error_responses: raise_error_responses,
          config: config
        )
      end

      @handler_mutex.synchronize do
        register_handler(handler)
        @inline_handler = handler
      end
    end

    # Checks whether the currently registered handler is the inline handler that
    # {.inline!} registers.
    #
    # @return [Boolean] Whether the inline handler is registered.
    def inline?
      @handler_mutex.synchronize { !@handler.nil? && @handler.equal?(@inline_handler) }
    end

    # Checks whether a request handler is registered.
    #
    # @return [Boolean] Whether a handler is registered.
    def handler_registered?
      @handler_mutex.synchronize { !@handler.nil? }
    end

    # Runs a request inline (synchronously and in process) through
    # {SynchronousExecutor}. The callback runs with the response or the error before
    # this method returns.
    #
    # @param request [Request] The HTTP request to run.
    # @param callback [Class, String] The callback class or its name.
    # @param callback_args [Hash, nil] JSON-compatible callback arguments.
    # @param raise_error_responses [Boolean, nil] Whether to report non-success
    #   responses as errors. Defaults to the configuration setting.
    # @param config [Configuration, nil] The configuration to run the request against.
    #   Defaults to {.default_configuration}, or to a lazily created configuration
    #   that includes any secrets registered with {.register_secret}.
    # @return [String] The request ID.
    def execute_inline(request:, callback:, callback_args: nil, raise_error_responses: nil, config: nil)
      config ||= default_configuration || inline_configuration
      raise_error_responses = config.raise_error_responses if raise_error_responses.nil?

      task = RequestTask.new(
        request: request,
        task_handler: InlineTaskHandler.new,
        callback: callback,
        callback_args: callback_args,
        raise_error_responses: raise_error_responses,
        default_max_redirects: config.max_redirects
      )

      SynchronousExecutor.new(task, config: config).call

      task.id
    end

    # Runs the registered request handler with the given request parameters.
    #
    # @param request [Request] The HTTP request to handle.
    # @param callback [Class, String] The callback class or its name.
    # @param callback_args [Hash, nil] JSON-compatible callback arguments.
    # @param raise_error_responses [Boolean, nil] Whether to report non-success
    #   responses as errors.
    # @return [Object] The return value from the registered request handler.
    # @raise [RuntimeError] If no handler is registered.
    def execute(request:, callback:, callback_args: nil, raise_error_responses: nil)
      handler = @handler_mutex.synchronize { @handler }

      unless handler
        raise "No request handler registered; you must register a PatientHttp handler before executing requests"
      end

      handler.call(
        request: request,
        callback: callback,
        callback_args: callback_args,
        raise_error_responses: raise_error_responses
      )
    end

    # Enqueues an HTTP GET request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options forwarded to {.request}.
    # @return [Object] The return value from the registered request handler.
    def get(uri, callback:, **kwargs)
      request(:get, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP HEAD request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options forwarded to {.request}.
    # @return [Object] The return value from the registered request handler.
    def head(uri, callback:, **kwargs)
      request(:head, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP POST request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options forwarded to {.request}.
    # @return [Object] The return value from the registered request handler.
    def post(uri, callback:, **kwargs)
      request(:post, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP PUT request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options forwarded to {.request}.
    # @return [Object] The return value from the registered request handler.
    def put(uri, callback:, **kwargs)
      request(:put, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP PATCH request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options forwarded to {.request}.
    # @return [Object] The return value from the registered request handler.
    def patch(uri, callback:, **kwargs)
      request(:patch, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP DELETE request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options forwarded to {.request}.
    # @return [Object] The return value from the registered request handler.
    def delete(uri, callback:, **kwargs)
      request(:delete, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP QUERY request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options forwarded to {.request}.
    # @return [Object] The return value from the registered request handler.
    def query(uri, callback:, **kwargs)
      request(:query, uri, callback: callback, **kwargs)
    end

    # Builds and dispatches an HTTP request.
    #
    # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`,
    #   `:patch`, `:delete`, or `:query`.
    # @param url [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param headers [Hash, nil] The request headers.
    # @param body [String, nil] The raw request body.
    # @param json [Hash, Array, nil] A JSON payload that the request layer encodes.
    # @param params [Hash, nil] The query parameters.
    # @param timeout [Numeric, nil] The timeout in seconds for this request.
    # @param raise_error_responses [Boolean, nil] Whether to report non-success
    #   responses as errors.
    # @param callback_args [Hash, nil] JSON-compatible callback arguments.
    # @param max_redirects [Integer, nil] The maximum number of redirects to follow.
    #   Use nil for the configured default, or 0 to disable redirects.
    # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a
    #   redirect that changes the HTTP method. Use nil for the configured default.
    # @param redirect_strip_headers [String, Array<String>, nil] Header names (case
    #   insensitive) to strip from redirected requests, in addition to the configured
    #   names.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
    #   preprocessors registered on the configuration to apply to the request when it
    #   is sent.
    # @param processor [String, Symbol, nil] The name of the processor that runs the
    #   request. Handlers that support named processors route on this value.
    # @return [Object] The return value from the registered request handler.
    def request(
      method,
      url,
      callback:,
      headers: nil,
      body: nil,
      json: nil,
      params: nil,
      timeout: nil,
      raise_error_responses: nil,
      callback_args: nil,
      max_redirects: nil,
      follow_method_changing_redirects: nil,
      redirect_strip_headers: nil,
      preprocessors: nil,
      processor: nil
    )
      request = Request.new(
        method,
        url,
        body: body,
        json: json,
        headers: headers,
        params: params,
        timeout: timeout,
        max_redirects: max_redirects,
        follow_method_changing_redirects: follow_method_changing_redirects,
        redirect_strip_headers: redirect_strip_headers,
        preprocessors: preprocessors,
        processor: processor
      )
      execute(
        request: request,
        callback: callback,
        callback_args: callback_args,
        raise_error_responses: raise_error_responses
      )
    end

    # Builds a reference to a named secret to use as a sensitive header value or query
    # parameter value when you build a request.
    #
    # The reference holds only the name of the secret. The processor resolves the
    # value at send time from the secrets registered on the configuration.
    #
    # @param name [String, Symbol] The name of the secret to reference.
    # @return [SecretReference] A reference to the named secret.
    # @see Configuration#register_secret
    def secret(name)
      SecretReference.new(name)
    end

    # Registers a named secret at the module level, independent of any configuration.
    #
    # Secrets registered here apply to the {.default_configuration}—immediately if one
    # is already set, or as soon as one is set later—and to the configuration used for
    # inline execution. Boot order therefore does not matter: your application code
    # can register secrets before or after the job system integration gem configures
    # the processor.
    #
    # @param name [String, Symbol] The secret name.
    # @param value [Object, nil] The secret value. Omit this when you provide a block.
    # @yield [name] A block that returns the secret value. Omit this when you provide
    #   a value.
    # @return [void]
    # @raise [ArgumentError] If neither or both of the value and the block are
    #   provided.
    # @see Configuration#register_secret
    def register_secret(name, value = nil, &block)
      if value.nil? && block.nil?
        raise ArgumentError.new("register_secret requires a value or a block")
      end

      if !value.nil? && block
        raise ArgumentError.new("register_secret accepts either a value or a block, not both")
      end

      @config_mutex.synchronize do
        secret_value = block || value
        @module_secrets[name.to_s] = secret_value
        @default_configuration&.register_secret(name, secret_value)
        @inline_configuration&.register_secret(name, secret_value)
      end
    end

    # Checks whether a secret name is registered, either at the module level with
    # {.register_secret} or on the {.default_configuration}.
    #
    # @param name [String, Symbol] The secret name.
    # @return [Boolean] Whether the secret is registered.
    def secret_registered?(name)
      @config_mutex.synchronize do
        return true if @module_secrets.include?(name.to_s)

        !@default_configuration.nil? && @default_configuration.secret_manager.include?(name)
      end
    end

    # Returns the default configuration, which inline execution uses when no other
    # configuration is provided.
    #
    # Job system integration gems must set this at the end of their configure step, so
    # that module-level secrets registered with {.register_secret} apply to the
    # configuration that the processor runs with.
    #
    # @return [Configuration, nil] The default configuration.
    def default_configuration
      @config_mutex.synchronize { @default_configuration }
    end

    # Sets the default configuration. Any secrets registered with {.register_secret}
    # apply to it. The module-level registry is retained, so assigning a new
    # configuration applies the same secrets again.
    #
    # @param config [Configuration, nil] The configuration to use as the default.
    # @return [void]
    def default_configuration=(config)
      @config_mutex.synchronize do
        @default_configuration = config
        apply_module_secrets(config) if config
      end
    end

    private

    # Returns the lazily created configuration that inline execution uses when no
    # explicit or default configuration is available. Module-level secrets apply to
    # it.
    #
    # @return [Configuration] The inline configuration.
    def inline_configuration
      @config_mutex.synchronize do
        @inline_configuration ||= Configuration.new.tap { |config| apply_module_secrets(config) }
      end
    end

    # Applies all module-level secrets to the given configuration.
    #
    # @param config [Configuration] The configuration to apply the secrets to.
    # @return [void]
    def apply_module_secrets(config)
      @module_secrets.each { |name, value| config.register_secret(name, value) }
    end

    # Validates that the handler accepts the required keyword arguments.
    #
    # @param handler [#call] The handler to validate.
    # @return [void]
    # @raise [ArgumentError] If the handler does not accept the required keyword
    #   arguments.
    def validate_handler_parameters!(handler)
      required_keywords = %i[request callback callback_args raise_error_responses]

      # Get the parameters of the handler's call method
      method_obj = handler.is_a?(Proc) ? handler : handler.method(:call)
      params = method_obj.parameters

      # Check if handler has keyword rest parameter (**kwargs)
      has_keyrest = params.any? { |type, _name| type == :keyrest }
      return if has_keyrest

      # rubocop:disable Style/HashSlice
      positional_params = params.select { |type, _name| %i[req opt].include?(type) }
      if positional_params.any?
        raise ArgumentError.new(
          "Handler must not accept positional parameters. " \
          "Found: #{positional_params.map { |_type, name| name }.join(", ")}"
        )
      end

      keyword_params = params.select { |type, _name| %i[keyreq key].include?(type) }
      keyword_names = keyword_params.map { |_type, name| name }

      missing_keywords = required_keywords - keyword_names
      if missing_keywords.any?
        raise ArgumentError.new(
          "Handler must accept keyword arguments: " \
          "#{required_keywords.join(", ")}. " \
          "Missing: #{missing_keywords.join(", ")}"
        )
      end

      required_keyword_names = keyword_params
        .select { |type, _name| type == :keyreq }
        .map { |_type, name| name }
      # rubocop:enable Style/HashSlice
      extra_required_keywords = required_keyword_names - required_keywords
      return unless extra_required_keywords.any?

      raise ArgumentError.new(
        "Handler must not have extra required keyword parameters. " \
        "Found: #{extra_required_keywords.join(", ")}"
      )
    end
  end
end
