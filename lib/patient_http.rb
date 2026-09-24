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

# An asynchronous HTTP connection pool for Ruby applications.
#
# This module provides the following:
#
# - Asynchronous HTTP request processing with Ruby's fiber scheduler.
# - Connection pooling with HTTP/2 support.
# - Configurable timeouts, retries, and proxy support.
# - Typed errors.
#
# You can use this module on its own or integrate it with a job system, such as
# Sidekiq, through an adapter.
module PatientHttp
  # Raised when you enqueue a request while the processor is not running.
  class NotRunningError < StandardError; end

  # Raised when you enqueue a request while the processor is at maximum capacity.
  class MaxCapacityError < StandardError; end

  # Raised when a response body exceeds the configured `max_response_size`.
  class ResponseTooLargeError < StandardError; end

  # Raised when a request names a processor that is not configured. Handlers
  # that support named processors raise this error at enqueue time. The
  # executing side raises it for a job that names an unconfigured processor, so
  # the job system retries the job instead of dropping it.
  class UnknownProcessorError < StandardError; end

  # HTTP redirect status codes that are followed when a `Location` header is present.
  # A 300 response is followed only when the server names a preferred choice in `Location`.
  FOLLOWABLE_REDIRECT_STATUSES = [300, 301, 302, 303, 307, 308].freeze

  # The gem version.
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
  autoload :ConnectionEndpoint, File.join(__dir__, "patient_http/connection_endpoint")
  autoload :Encryptor, File.join(__dir__, "patient_http/encryptor")
  autoload :Error, File.join(__dir__, "patient_http/error")
  autoload :ExternalStorage, File.join(__dir__, "patient_http/external_storage")
  autoload :HttpError, File.join(__dir__, "patient_http/http_error")
  autoload :HttpHeaders, File.join(__dir__, "patient_http/http_headers")
  autoload :ImmediateRetries, File.join(__dir__, "patient_http/immediate_retries")
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
    # Returns `true` if the library is running in testing mode.
    #
    # @api private
    def testing?
      @testing
    end

    # Sets testing mode.
    #
    # @api private
    def testing=(value)
      @testing = !!value
    end

    # Registers a request handler that processes each request. The handler must be
    # a block or an object that responds to `call`.
    #
    # The handler receives the keyword arguments `request`, `callback`,
    # `callback_args`, and `raise_error_responses`. It should return the ID of the
    # enqueued request.
    #
    # @param callable [#call, nil] A callable object that handles requests.
    # @yield [request, callback, callback_args, raise_error_responses] The block to use
    #   as the request handler.
    # @raise [ArgumentError] If you provide neither a callable nor a block, or both.
    # @raise [ArgumentError] If the provided callable does not respond to `call`.
    # @raise [ArgumentError] If the handler does not support the required keyword arguments.
    # @return [#call] The registered handler.
    def register_handler(callable = nil, &block)
      raise ArgumentError.new("Must provide a callable object or a block") unless callable || block_given?
      raise ArgumentError.new("Cannot provide both a callable object and a block") if callable && block_given?

      handler = callable || block
      raise ArgumentError.new("Handler must be a callable object or a block") unless handler.respond_to?(:call)

      validate_handler_parameters!(handler)

      @handler_mutex.synchronize { @handler = handler }
    end

    # Registers a request handler and raises an error if a handler is already registered.
    #
    # Use this method instead of {.register_handler} to prevent registering a
    # handler twice by accident.
    #
    # @param callable [#call, nil] A callable object that handles requests.
    # @yield [request, callback, callback_args, raise_error_responses] The block to use
    #   as the request handler.
    # @raise [RuntimeError] If a handler is already registered.
    # @raise [ArgumentError] If you provide neither a callable nor a block, or both.
    # @raise [ArgumentError] If the provided callable does not respond to `call`.
    # @raise [ArgumentError] If the handler does not support the required keyword arguments.
    # @return [#call] The registered handler.
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
    # @param handler [#call, nil] The handler to unregister. If you provide a handler, the
    #   method unregisters the current handler only if it matches.
    # @return [void]
    def unregister_handler(handler = nil)
      @handler_mutex.synchronize do
        @handler = nil if @handler == handler || handler.nil?
      end
    end

    # Registers a request handler that executes requests inline, synchronously in
    # the current process, instead of dispatching them to a job system.
    #
    # Use this handler in consoles, tests, and development environments that don't
    # have a job system integration gem configured. Each request runs through
    # {SynchronousExecutor}, and the handler invokes the callback on the calling
    # thread before it returns.
    #
    # @param config [Configuration, nil] The configuration to execute requests with.
    #   Defaults to {.default_configuration}. If that isn't set, a configuration is
    #   created on first use that includes any secrets registered with {.register_secret}.
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

    # Returns `true` if the registered handler is the inline handler that {.inline!}
    # registers.
    #
    # @return [Boolean]
    def inline?
      @handler_mutex.synchronize { !@handler.nil? && @handler.equal?(@inline_handler) }
    end

    # Returns `true` if a request handler is registered.
    #
    # @return [Boolean]
    def handler_registered?
      @handler_mutex.synchronize { !@handler.nil? }
    end

    # Executes a request inline, synchronously in the current process, through
    # {SynchronousExecutor}. The callback receives the response or error before
    # this method returns.
    #
    # @param request [Request] The HTTP request to execute.
    # @param callback [Class, String] The callback class or class name.
    # @param callback_args [Hash, nil] JSON-compatible callback arguments.
    # @param raise_error_responses [Boolean, nil] If `true`, non-success responses are
    #   reported as errors. Defaults to the configuration setting.
    # @param config [Configuration, nil] The configuration to execute the request with.
    #   Defaults to {.default_configuration}. If that isn't set, a configuration is
    #   created on first use that includes any secrets registered with {.register_secret}.
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

    # Executes the registered request handler with the given request parameters.
    #
    # @param request [Request] The HTTP request to handle.
    # @param callback [Class, String] The callback class or class name.
    # @param callback_args [Hash, nil] JSON-compatible callback arguments.
    # @param raise_error_responses [Boolean, nil] If `true`, non-success responses are
    #   reported as errors.
    # @raise [RuntimeError] If no handler is registered.
    # @return [Object] The return value of the registered request handler.
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
    # @param kwargs [Hash] Additional options to pass to {.request}.
    # @return [Object] The return value of the registered request handler.
    def get(uri, callback:, **kwargs)
      request(:get, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP HEAD request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options to pass to {.request}.
    # @return [Object] The return value of the registered request handler.
    def head(uri, callback:, **kwargs)
      request(:head, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP POST request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options to pass to {.request}.
    # @return [Object] The return value of the registered request handler.
    def post(uri, callback:, **kwargs)
      request(:post, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP PUT request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options to pass to {.request}.
    # @return [Object] The return value of the registered request handler.
    def put(uri, callback:, **kwargs)
      request(:put, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP PATCH request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options to pass to {.request}.
    # @return [Object] The return value of the registered request handler.
    def patch(uri, callback:, **kwargs)
      request(:patch, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP DELETE request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options to pass to {.request}.
    # @return [Object] The return value of the registered request handler.
    def delete(uri, callback:, **kwargs)
      request(:delete, uri, callback: callback, **kwargs)
    end

    # Enqueues an HTTP QUERY request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param kwargs [Hash] Additional options to pass to {.request}.
    # @return [Object] The return value of the registered request handler.
    def query(uri, callback:, **kwargs)
      request(:query, uri, callback: callback, **kwargs)
    end

    # Builds and dispatches an HTTP request.
    #
    # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`, `:patch`,
    #   `:delete`, or `:query`.
    # @param url [String] The absolute URL.
    # @param callback [Class, String] The callback class that handles the response.
    # @param headers [Hash, nil] The request headers.
    # @param body [String, nil] The raw request body.
    # @param json [Hash, Array, nil] A payload to encode as the JSON request body.
    # @param params [Hash, nil] The query parameters.
    # @param timeout [Numeric, nil] The timeout for this request, in seconds.
    # @param raise_error_responses [Boolean, nil] If `true`, non-success responses are
    #   reported as errors.
    # @param callback_args [Hash, nil] JSON-compatible callback arguments.
    # @param max_redirects [Integer, nil] The maximum number of redirects to follow. `nil`
    #   uses the configuration default, and `0` disables redirects.
    # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a redirect that
    #   changes the HTTP method. `nil` uses the configuration default.
    # @param redirect_strip_headers [String, Array<String>, nil] Header names to strip from
    #   redirected requests, in addition to the configured names. Names are case insensitive.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
    #   preprocessors, registered on the configuration, to apply when the request is sent.
    # @param processor [String, Symbol, nil] The name of the processor that executes the
    #   request. Handlers that support named processors route requests by this value.
    # @return [Object] The return value of the registered request handler.
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

    # Builds a reference to a named secret. Use the reference as a sensitive header
    # or query parameter value when you build a request.
    #
    # The reference holds only the name of the secret. The processor resolves the
    # value when it sends the request, using the secrets registered on its
    # configuration.
    #
    # @param name [String, Symbol] The name of the secret to reference.
    # @return [SecretReference] A reference to the named secret.
    # @see Configuration#register_secret
    def secret(name)
      SecretReference.new(name)
    end

    # Registers a named secret at the module level, independent of any configuration.
    #
    # Secrets registered with this method are applied to {.default_configuration} and
    # to the configuration used for inline execution. If no default configuration is
    # set yet, the secrets are applied when one is set. Application code can
    # therefore register secrets before or after the job system integration gem
    # configures the processor.
    #
    # @param name [String, Symbol] The secret name.
    # @param value [Object, nil] The secret value. Omit this argument if you provide a block.
    # @yield [name] A block that returns the secret value. Omit the block if you provide a value.
    # @raise [ArgumentError] If you provide neither a value nor a block, or both.
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

    # Returns `true` if a secret name is registered, either at the module level with
    # {.register_secret} or on {.default_configuration}.
    #
    # @param name [String, Symbol] The secret name.
    # @return [Boolean]
    def secret_registered?(name)
      @config_mutex.synchronize do
        return true if @module_secrets.include?(name.to_s)

        !@default_configuration.nil? && @default_configuration.secret_manager.include?(name)
      end
    end

    # Returns the default configuration. Inline execution uses this configuration
    # when you don't provide one.
    #
    # Job system integration gems should set the default configuration at the end
    # of their configuration step. The secrets registered with {.register_secret}
    # are then applied to the configuration that the processor uses.
    #
    # @return [Configuration, nil] The default configuration.
    def default_configuration
      @config_mutex.synchronize { @default_configuration }
    end

    # Sets the default configuration and applies any secrets registered with
    # {.register_secret} to it. The module keeps its secrets, so if you assign a
    # new configuration later, the same secrets are applied to it.
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

    # Returns the configuration for inline execution when no explicit or default
    # configuration is available. The configuration is created on first use, and
    # module-level secrets are applied to it.
    #
    # @return [Configuration]
    def inline_configuration
      @config_mutex.synchronize do
        @inline_configuration ||= Configuration.new.tap { |config| apply_module_secrets(config) }
      end
    end

    # Applies all module-level secrets to the given configuration.
    #
    # @param config [Configuration] The configuration to apply secrets to.
    # @return [void]
    def apply_module_secrets(config)
      @module_secrets.each { |name, value| config.register_secret(name, value) }
    end

    # Validates that the handler accepts the required keyword arguments.
    #
    # @param handler [#call] The handler to validate.
    # @raise [ArgumentError] If the handler does not support the required keyword arguments.
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
