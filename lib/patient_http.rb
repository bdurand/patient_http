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

# Runs HTTP requests on an async I/O processor and passes each result to a
# callback service.
#
# The processor runs in a dedicated thread and uses Ruby's fiber scheduler, so
# one thread can run hundreds of requests at the same time. A job system
# integration gem, such as `patient_http-sidekiq` or `patient_http-solid_queue`,
# runs the processor and calls the callbacks in background jobs.
#
# @example Make a request
#   PatientHttp.get(
#     "https://api.example.com/users/123",
#     callback: FetchUserCallback,
#     callback_args: {user_id: 123}
#   )
module PatientHttp
  # Raised when a request is enqueued on a processor that isn't running.
  class NotRunningError < StandardError; end

  # Raised when a request is enqueued on a processor that is at
  # `max_connections`.
  class MaxCapacityError < StandardError; end

  # Raised when a response body is larger than `max_response_size`.
  class ResponseTooLargeError < StandardError; end

  # Raised when a request names a processor that isn't configured. The job
  # system then retries the job instead of dropping it.
  class UnknownProcessorError < StandardError; end

  # The redirect status codes that are followed when the response has a
  # `Location` header. A 300 response is followed only when `Location` names the
  # server's preferred choice.
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
  @configuration_provider = nil
  @module_secrets = {}
  @config_mutex = Monitor.new

  class << self
    # Returns whether the process runs in test mode. The value is `true` when
    # `RAILS_ENV`, `RACK_ENV`, or `APP_ENV` is `test`.
    #
    # @return [Boolean] `true` in test mode.
    # @api private
    def testing?
      @testing
    end

    # Sets whether the process runs in test mode.
    #
    # @param value [Boolean] `true` to turn on test mode.
    # @return [void]
    # @api private
    def testing=(value)
      @testing = !!value
    end

    # Registers the request handler. The handler receives every request made
    # with the `PatientHttp` module methods and {RequestHelper}. Job system
    # integration gems register a handler when they load.
    #
    # The handler receives the `request`, `callback`, `callback_args`, and
    # `raise_error_responses` keyword arguments. It should return the request ID.
    #
    # @param callable [#call, nil] An object that responds to `call`. Omit it
    #   when you give a block.
    # @yield [request:, callback:, callback_args:, raise_error_responses:] The
    #   handler. Omit it when you give a callable.
    # @raise [ArgumentError] If you give both a callable and a block, or neither.
    # @raise [ArgumentError] If the callable doesn't respond to `call`.
    # @raise [ArgumentError] If the handler doesn't accept the required keyword
    #   arguments.
    # @return [#call] The registered handler.
    def register_handler(callable = nil, &block)
      raise ArgumentError.new("Must provide a callable object or a block") unless callable || block_given?
      raise ArgumentError.new("Cannot provide both a callable object and a block") if callable && block_given?

      handler = callable || block
      raise ArgumentError.new("Handler must be a callable object or a block") unless handler.respond_to?(:call)

      validate_handler_parameters!(handler)

      @handler_mutex.synchronize { @handler = handler }
    end

    # Registers the request handler, and raises an error if a handler is
    # already registered. Unlike {.register_handler}, this method can't replace
    # a handler by accident.
    #
    # @param callable [#call, nil] An object that responds to `call`. Omit it
    #   when you give a block.
    # @yield [request:, callback:, callback_args:, raise_error_responses:] The
    #   handler. Omit it when you give a callable.
    # @raise [RuntimeError] If a handler is already registered.
    # @raise [ArgumentError] If you give both a callable and a block, or neither.
    # @raise [ArgumentError] If the callable doesn't respond to `call`.
    # @raise [ArgumentError] If the handler doesn't accept the required keyword
    #   arguments.
    # @return [#call] The registered handler.
    def register_handler!(callable = nil, &block)
      @handler_mutex.synchronize do
        if @handler
          raise "A PatientHttp handler is already registered. Unregister the existing handler before registering a new one."
        end

        register_handler(callable, &block)
      end
    end

    # Removes the registered request handler.
    #
    # @param handler [#call, nil] If given, the handler is removed only if it's
    #   the registered handler.
    # @return [void]
    def unregister_handler(handler = nil)
      @handler_mutex.synchronize do
        @handler = nil if @handler == handler || handler.nil?
      end
    end

    # Registers a request handler that runs each request inline, on the calling
    # thread, instead of sending it to a job system.
    #
    # Use it in consoles, tests, and development environments that don't load a
    # job system integration gem. Each request runs through
    # {SynchronousExecutor}, and the callback runs before the request method
    # returns.
    #
    # @param config [Configuration, nil] The configuration for the requests. If
    #   `nil`, {.configuration} applies.
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

    # Returns whether the registered handler is the inline handler from
    # {.inline!}.
    #
    # @return [Boolean] `true` if requests run inline.
    def inline?
      @handler_mutex.synchronize { !@handler.nil? && @handler.equal?(@inline_handler) }
    end

    # Returns whether a request handler is registered.
    #
    # @return [Boolean] `true` if a handler is registered.
    def handler_registered?
      @handler_mutex.synchronize { !@handler.nil? }
    end

    # Runs a request inline, on the calling thread, through
    # {SynchronousExecutor}. The callback runs with the response or error
    # before this method returns. The registered handler isn't used.
    #
    # @param request [Request] The HTTP request.
    # @param callback [Class, String] The callback service class, or its name.
    # @param callback_args [Hash, nil] The JSON-compatible arguments to pass to the
    #   callback.
    # @param raise_error_responses [Boolean, nil] If `true`, non-2xx responses go
    #   to the `on_error` callback as an {HttpError}. If `nil`, the configuration
    #   value applies.
    # @param config [Configuration, nil] The configuration for the request. If
    #   `nil`, {.configuration} applies.
    # @return [String] The request ID.
    def execute_inline(request:, callback:, callback_args: nil, raise_error_responses: nil, config: nil)
      config ||= configuration
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

    # Sends a request to the registered request handler.
    #
    # @param request [Request] The HTTP request.
    # @param callback [Class, String] The callback service class, or its name.
    # @param callback_args [Hash, nil] The JSON-compatible arguments to pass to the
    #   callback.
    # @param raise_error_responses [Boolean, nil] If `true`, non-2xx responses go
    #   to the `on_error` callback as an {HttpError}. If `nil`, the configuration
    #   value applies.
    # @raise [RuntimeError] If no handler is registered.
    # @return [Object] The value that the request handler returns.
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

    # Makes an async GET request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback service class, or its name.
    # @param kwargs [Hash] The request options. See {.request}.
    # @return [Object] The value that the request handler returns.
    def get(uri, callback:, **kwargs)
      request(:get, uri, callback: callback, **kwargs)
    end

    # Makes an async HEAD request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback service class, or its name.
    # @param kwargs [Hash] The request options. See {.request}.
    # @return [Object] The value that the request handler returns.
    def head(uri, callback:, **kwargs)
      request(:head, uri, callback: callback, **kwargs)
    end

    # Makes an async POST request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback service class, or its name.
    # @param kwargs [Hash] The request options. See {.request}.
    # @return [Object] The value that the request handler returns.
    def post(uri, callback:, **kwargs)
      request(:post, uri, callback: callback, **kwargs)
    end

    # Makes an async PUT request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback service class, or its name.
    # @param kwargs [Hash] The request options. See {.request}.
    # @return [Object] The value that the request handler returns.
    def put(uri, callback:, **kwargs)
      request(:put, uri, callback: callback, **kwargs)
    end

    # Makes an async PATCH request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback service class, or its name.
    # @param kwargs [Hash] The request options. See {.request}.
    # @return [Object] The value that the request handler returns.
    def patch(uri, callback:, **kwargs)
      request(:patch, uri, callback: callback, **kwargs)
    end

    # Makes an async DELETE request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback service class, or its name.
    # @param kwargs [Hash] The request options. See {.request}.
    # @return [Object] The value that the request handler returns.
    def delete(uri, callback:, **kwargs)
      request(:delete, uri, callback: callback, **kwargs)
    end

    # Makes an async QUERY request.
    #
    # @param uri [String] The absolute URL.
    # @param callback [Class, String] The callback service class, or its name.
    # @param kwargs [Hash] The request options. See {.request}.
    # @return [Object] The value that the request handler returns.
    def query(uri, callback:, **kwargs)
      request(:query, uri, callback: callback, **kwargs)
    end

    # Makes an async HTTP request. The request goes to the registered request
    # handler, and this method returns without waiting for the response.
    #
    # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`,
    #   `:patch`, `:delete`, or `:query`.
    # @param url [String] The absolute URL.
    # @param callback [Class, String] The callback service class, or its name.
    # @param headers [Hash, nil] The request headers.
    # @param body [String, nil] The request body.
    # @param json [Hash, Array, nil] An object to send as a JSON body. Can't be
    #   combined with `body`.
    # @param params [Hash, nil] The query parameters to add to the URL.
    # @param timeout [Numeric, nil] The request timeout in seconds.
    # @param raise_error_responses [Boolean, nil] If `true`, non-2xx responses go
    #   to the `on_error` callback as an {HttpError}. If `nil`, the configuration
    #   value applies.
    # @param callback_args [Hash, nil] The JSON-compatible arguments to pass to the
    #   callback.
    # @param max_redirects [Integer, nil] The maximum number of redirects to
    #   follow. If `0`, redirects aren't followed. If `nil`, the configuration
    #   value applies.
    # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a
    #   redirect that changes the HTTP method. If `nil`, the configuration value
    #   applies.
    # @param redirect_strip_headers [String, Array<String>, nil] The names of headers
    #   to remove from redirected requests, in addition to the configured names.
    #   Names are case insensitive.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
    #   the registered preprocessors that run on the request before it's sent.
    # @param processor [String, Symbol, nil] The name of the processor that runs
    #   the request. Handlers that support named processors use this value.
    # @return [Object] The value that the request handler returns.
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

    # Returns a reference to a named secret. Use the reference as a header or
    # query parameter value.
    #
    # The reference holds only the name of the secret. The processor resolves
    # the value from the registered secrets when it sends the request, so the
    # value isn't stored in the job queue.
    #
    # @param name [String, Symbol] The secret name.
    # @return [SecretReference] The reference to the secret.
    # @see Configuration#register_secret
    def secret(name)
      SecretReference.new(name)
    end

    # Registers a named secret at the module level.
    #
    # The secret is added to {.configuration} now if the configuration exists,
    # or when it's created. As a result, load order doesn't matter. You can
    # register secrets before or after the job system integration gem loads.
    #
    # @param name [String, Symbol] The secret name.
    # @param value [Object, nil] The secret value. Omit it when you give a block.
    # @yield [name] Returns the secret value. The block runs each time the secret
    #   is resolved. Omit it when you give a value.
    # @raise [ArgumentError] If you give both a value and a block, or neither.
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
      end
    end

    # Returns whether a secret is registered, at the module level with
    # {.register_secret} or on the {.configuration}.
    #
    # @param name [String, Symbol] The secret name.
    # @return [Boolean] `true` if the secret is registered.
    def secret_registered?(name)
      return true if @config_mutex.synchronize { @module_secrets.include?(name.to_s) }

      config = default_configuration
      !config.nil? && config.secret_manager.include?(name)
    end

    # Registers the object that builds the configuration for this process.
    #
    # Job system integration gems call this method when they load. Then
    # {.configure} and {.configuration} use the integration's configuration
    # class, which adds the options for that job system. Applications don't
    # call this method.
    #
    # This module stores the configuration, so a process has one configuration
    # object. If a configuration exists when the provider registers, it's
    # discarded, and the provider builds a new one on next use.
    #
    # @param provider [#new_configuration, #configure] The integration module.
    # @raise [ArgumentError] If the provider doesn't respond to
    #   `new_configuration` and `configure`.
    # @return [Object] The registered provider.
    # @api private
    def register_configuration_provider(provider)
      unless provider.respond_to?(:new_configuration) && provider.respond_to?(:configure)
        raise ArgumentError.new("A configuration provider must respond to #new_configuration and #configure")
      end

      @config_mutex.synchronize do
        previous = @configuration_provider

        if previous && !previous.equal?(provider)
          warn(
            "PatientHttp: #{provider} is replacing #{previous} as the configuration " \
            "provider. Loading more than one patient_http job-system integration in a process is not " \
            "supported; keep only one of them in your Gemfile."
          )
        end

        @configuration_provider = provider

        # A configuration built before this provider was registered was not built
        # by it, so it does not carry the provider's options. Discard it so the
        # next read builds one through the provider.
        if @default_configuration && !previous.equal?(provider)
          warn(
            "PatientHttp: discarding the configuration that was built before #{provider} was loaded; " \
            "options set on it are lost. Configure PatientHttp after requiring the job-system integration."
          )
          @default_configuration = nil
        end
      end

      provider
    end

    # Returns the registered configuration provider.
    #
    # @return [Object, nil] The provider, or `nil` if no job system integration
    #   gem is loaded.
    # @api private
    def configuration_provider
      @config_mutex.synchronize { @configuration_provider }
    end

    # Returns the configuration for this process, and creates it on first use.
    #
    # If a job system integration gem is loaded, the configuration is an
    # instance of that integration's configuration class, which adds the
    # options for that job system. Otherwise, it's a {Configuration}. Secrets
    # registered with {.register_secret} are added to it.
    #
    # @return [Configuration] The configuration.
    def configuration
      @config_mutex.synchronize do
        @default_configuration ||= begin
          provider = @configuration_provider
          config = provider ? provider.new_configuration : Configuration.new
          apply_module_secrets(config)
          config
        end
      end
    end

    # Yields the configuration to a block.
    #
    # Use this method to configure the gem with any job system. If an
    # integration gem is loaded, the block receives that integration's
    # configuration. Otherwise, it receives a {Configuration}.
    #
    # Every call yields the same configuration object, so options accumulate.
    # Several initializers can each set options without overwriting one
    # another.
    #
    # @example
    #   PatientHttp.configure do |config|
    #     config.max_connections = 512
    #     config.register_secret(:api_token) { ENV["API_TOKEN"] }
    #   end
    #
    # @yield [config] The block that sets configuration options.
    # @yieldparam config [Configuration] The configuration.
    # @return [Configuration] The configuration.
    def configure(&block)
      provider = configuration_provider
      return provider.configure(&block) if provider

      config = configuration
      yield(config) if block
      config
    end

    # Returns the configuration if it exists. Unlike {.configuration}, this
    # method doesn't create the configuration.
    #
    # @return [Configuration, nil] The configuration, or `nil` if it doesn't
    #   exist yet.
    def default_configuration
      @config_mutex.synchronize { @default_configuration }
    end

    # Replaces the configuration. Intended for tests. Applications use
    # {.configure} instead.
    #
    # Secrets registered with {.register_secret} are added to the new
    # configuration. If `nil`, the configuration is discarded, and
    # {.configuration} builds a new one on next use.
    #
    # @param config [Configuration, nil] The configuration, or `nil` to build a
    #   new one on next use.
    # @return [void]
    def default_configuration=(config)
      @config_mutex.synchronize do
        @default_configuration = config
        apply_module_secrets(config) if config
      end
    end

    private

    # Adds the module-level secrets to a configuration.
    #
    # @param config [Configuration] The configuration.
    # @return [void]
    def apply_module_secrets(config)
      @module_secrets.each { |name, value| config.register_secret(name, value) }
    end

    # Validates that a handler accepts the required keyword arguments.
    #
    # @param handler [#call] The handler.
    # @raise [ArgumentError] If the handler doesn't accept the required keyword
    #   arguments.
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
