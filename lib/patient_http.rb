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

    private

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
