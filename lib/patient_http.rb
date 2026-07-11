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
# - Async HTTP request processing using Ruby's Fiber scheduler
# - Connection pooling with HTTP/2 support
# - Configurable timeouts, retries, and proxy support
# - Error handling with typed errors
#
# This module can be used standalone or integrated with job systems
# like Sidekiq via adapters.
module PatientHttp
  # Raised when trying to enqueue a request when the processor is not running
  class NotRunningError < StandardError; end

  class MaxCapacityError < StandardError; end

  class ResponseTooLargeError < StandardError; end

  # HTTP redirect status codes that should be followed
  FOLLOWABLE_REDIRECT_STATUSES = [301, 302, 303, 307, 308].freeze

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
    # Check if running in testing mode.
    #
    # @api private
    def testing?
      @testing
    end

    # Set testing mode.
    #
    # @api private
    def testing=(value)
      @testing = !!value
    end

    # Registers a request handler that will be called to process each request.
    # The handler must be a callable object (responds to `call`) or a block.
    #
    # The handler will receive keyword arguments: request, callback, callback_args,
    # and raise_error_responses. It should return the request id for the enqueued request.
    #
    # @param callable [#call, nil] A callable object that will handle requests.
    # @yield [request, callback, callback_args, raise_error_responses] If a block is given,
    #   it will be used as the request handler
    # @raise [ArgumentError] if neither a callable nor a block is provided, or if both are provided
    # @raise [ArgumentError] if the provided callable does not respond to `call`
    # @raise [ArgumentError] if the handler does not support the required keyword arguments
    # @return [#call] the registered handler
    def register_handler(callable = nil, &block)
      raise ArgumentError.new("Must provide a callable object or a block") unless callable || block_given?
      raise ArgumentError.new("Cannot provide both a callable object and a block") if callable && block_given?

      handler = callable || block
      raise ArgumentError.new("Handler must be a callable object or a block") unless handler.respond_to?(:call)

      validate_handler_parameters!(handler)

      @handler_mutex.synchronize { @handler = handler }
    end

    # Registers a request handler, raising an error if one is already registered.
    #
    # This is a safer alternative to {.register_handler} that prevents accidental
    # double-registration.
    #
    # @param callable [#call, nil] A callable object that will handle requests.
    # @yield [request, callback, callback_args, raise_error_responses] If a block is given,
    #   it will be used as the request handler
    # @raise [RuntimeError] if a handler is already registered
    # @raise [ArgumentError] if neither a callable nor a block is provided, or if both are provided
    # @raise [ArgumentError] if the provided callable does not respond to `call`
    # @raise [ArgumentError] if the handler does not support the required keyword arguments
    # @return [#call] the registered handler
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
    # @param handler [#call, nil] If provided, only unregisters if the given handler matches
    #   the current handler
    # @return [void]
    def unregister_handler(handler = nil)
      @handler_mutex.synchronize do
        @handler = nil if @handler == handler || handler.nil?
      end
    end

    # Registers a request handler that executes requests inline (synchronously,
    # in-process) instead of dispatching them to a job system.
    #
    # This is intended for consoles, tests, and development environments where no
    # job-system integration gem is configured. Each request runs through
    # {SynchronousExecutor} and the callback is invoked on the calling thread
    # before the handler returns.
    #
    # @param config [Configuration, nil] configuration to execute requests against.
    #   Defaults to {.default_configuration}, or a lazily created configuration that
    #   includes any secrets registered with {.register_secret}.
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

    # Check if the currently registered handler is the inline handler registered
    # by {.inline!}.
    #
    # @return [Boolean]
    def inline?
      @handler_mutex.synchronize { !@handler.nil? && @handler.equal?(@inline_handler) }
    end

    # Check if a request handler is registered.
    #
    # @return [Boolean]
    def handler_registered?
      @handler_mutex.synchronize { !@handler.nil? }
    end

    # Executes a request inline (synchronously, in-process) through
    # {SynchronousExecutor}, invoking the callback with the response or error
    # before returning.
    #
    # @param request [Request] the HTTP request to execute
    # @param callback [Class, String] the callback class or name
    # @param callback_args [Hash, nil] JSON-compatible callback arguments
    # @param raise_error_responses [Boolean, nil] when true, non-success responses are
    #   reported as errors; defaults to the configuration's setting
    # @param config [Configuration, nil] configuration to execute the request against.
    #   Defaults to {.default_configuration}, or a lazily created configuration that
    #   includes any secrets registered with {.register_secret}.
    # @return [String] the request id
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

    # Executes the registered request handler with the given request parameters.
    #
    # @param request [Request] the HTTP request to handle
    # @param callback [Class, String] the callback class or name
    # @param callback_args [Hash, nil] JSON-compatible callback arguments
    # @param raise_error_responses [Boolean, nil] when true, non-success responses are
    #   reported as errors
    # @raise [RuntimeError] if no handler is registered
    # @return [Object] return value from the registered request handler
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
    # @param uri [String] absolute URL
    # @param callback [Class, String] callback class to handle the response
    # @param kwargs [Hash] forwarded to `request`
    # @return [Object] return value from the registered request handler
    def get(uri, callback:, **kwargs)
      request(:get, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP POST request.
    #
    # @param uri [String] absolute URL
    # @param callback [Class, String] callback class to handle the response
    # @param kwargs [Hash] forwarded to `request`
    # @return [Object] return value from the registered request handler
    def post(uri, callback:, **kwargs)
      request(:post, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP PUT request.
    #
    # @param uri [String] absolute URL
    # @param callback [Class, String] callback class to handle the response
    # @param kwargs [Hash] forwarded to `request`
    # @return [Object] return value from the registered request handler
    def put(uri, callback:, **kwargs)
      request(:put, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP PATCH request.
    #
    # @param uri [String] absolute URL
    # @param callback [Class, String] callback class to handle the response
    # @param kwargs [Hash] forwarded to `request`
    # @return [Object] return value from the registered request handler
    def patch(uri, callback:, **kwargs)
      request(:patch, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP DELETE request.
    #
    # @param uri [String] absolute URL
    # @param callback [Class, String] callback class to handle the response
    # @param kwargs [Hash] forwarded to `request`
    # @return [Object] return value from the registered request handler
    def delete(uri, callback:, **kwargs)
      request(:delete, uri, callback: callback, **kwargs)
    end

    # Builds and dispatches an HTTP request.
    #
    # @param method [Symbol] HTTP method (`:get`, `:post`, `:put`, `:patch`, `:delete`)
    # @param url [String] absolute URL
    # @param callback [Class, String] callback class to handle the response
    # @param headers [Hash, nil] request headers
    # @param body [String, nil] raw request body
    # @param json [Hash, Array, nil] JSON payload encoded by the request layer
    # @param params [Hash, nil] query parameters
    # @param timeout [Numeric, nil] timeout in seconds for this request
    # @param raise_error_responses [Boolean, nil] when true, non-success responses are
    #   reported as errors
    # @param callback_args [Hash, nil] JSON-compatible callback arguments
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] names of preprocessors
    #   registered on the configuration to apply to the request when it is sent
    # @return [Object] return value from the registered request handler
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
      preprocessors: nil
    )
      request = Request.new(
        method,
        url,
        body: body,
        json: json,
        headers: headers,
        params: params,
        timeout: timeout,
        preprocessors: preprocessors
      )
      execute(
        request: request,
        callback: callback,
        callback_args: callback_args,
        raise_error_responses: raise_error_responses
      )
    end

    # Build a reference to a named secret for use as a sensitive header or query
    # parameter value when building a request.
    #
    # The reference holds only the secret's name; the value is resolved on the
    # processor side at send time using the secrets registered on the configuration.
    #
    # @param name [String, Symbol] the name of the secret to reference
    # @return [SecretReference] a reference to the named secret
    # @see Configuration#register_secret
    def secret(name)
      SecretReference.new(name)
    end

    # Register a named secret at the module level, independent of any configuration.
    #
    # Secrets registered here are applied to the {.default_configuration} (immediately
    # if one is already set, or when one is set later) and to the configuration used
    # for inline execution. This makes boot order irrelevant: application code can
    # register secrets before or after the job-system integration gem configures the
    # processor.
    #
    # @param name [String, Symbol] the secret name
    # @param value [Object, nil] the secret value (omit when providing a block)
    # @yield [name] a block that returns the secret value (omit when providing a value)
    # @raise [ArgumentError] if neither or both of value and block are provided
    # @return [void]
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

    # Check if a secret name is registered, either at the module level via
    # {.register_secret} or on the {.default_configuration}.
    #
    # @param name [String, Symbol] the secret name
    # @return [Boolean]
    def secret_registered?(name)
      @config_mutex.synchronize do
        return true if @module_secrets.include?(name.to_s)

        !@default_configuration.nil? && @default_configuration.secret_manager.include?(name)
      end
    end

    # The default configuration used for inline execution when none is provided.
    # Job-system integration gems should set this at the end of their configure
    # step so that module-level secrets registered with {.register_secret} are
    # applied to the configuration the processor runs with.
    #
    # @return [Configuration, nil] the default configuration
    def default_configuration
      @config_mutex.synchronize { @default_configuration }
    end

    # Set the default configuration. Any secrets registered with {.register_secret}
    # are applied to it; the module-level registry is retained, so re-assigning a
    # new configuration re-applies the same secrets.
    #
    # @param config [Configuration, nil] the configuration to use as the default
    # @return [void]
    def default_configuration=(config)
      @config_mutex.synchronize do
        @default_configuration = config
        apply_module_secrets(config) if config
      end
    end

    private

    # The lazily created configuration used for inline execution when no explicit
    # or default configuration is available. Module-level secrets are applied to it.
    #
    # @return [Configuration]
    def inline_configuration
      @config_mutex.synchronize do
        @inline_configuration ||= Configuration.new.tap { |config| apply_module_secrets(config) }
      end
    end

    # Apply all module-level secrets to the given configuration.
    #
    # @param config [Configuration] the configuration to apply secrets to
    # @return [void]
    def apply_module_secrets(config)
      @module_secrets.each { |name, value| config.register_secret(name, value) }
    end

    # Validates that the handler accepts the required keyword arguments.
    #
    # @param handler [#call] the handler to validate
    # @raise [ArgumentError] if the handler does not support the required keyword arguments
    # @return [void]
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
