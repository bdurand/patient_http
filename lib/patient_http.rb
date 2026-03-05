# frozen_string_literal: true

require "async"
require "async/http"
require "concurrent"
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
  autoload :Error, File.join(__dir__, "patient_http/error")
  autoload :ExternalStorage, File.join(__dir__, "patient_http/external_storage")
  autoload :HttpError, File.join(__dir__, "patient_http/http_error")
  autoload :HttpHeaders, File.join(__dir__, "patient_http/http_headers")
  autoload :LifecycleManager, File.join(__dir__, "patient_http/lifecycle_manager")
  autoload :Payload, File.join(__dir__, "patient_http/payload")
  autoload :PayloadStore, File.join(__dir__, "patient_http/payload_store")
  autoload :Processor, File.join(__dir__, "patient_http/processor")
  autoload :ProcessorObserver, File.join(__dir__, "patient_http/processor_observer")
  autoload :RecursiveRedirectError, File.join(__dir__, "patient_http/redirect_error")
  autoload :RedirectError, File.join(__dir__, "patient_http/redirect_error")
  autoload :Request, File.join(__dir__, "patient_http/request")
  autoload :RequestError, File.join(__dir__, "patient_http/request_error")
  autoload :RequestHelper, File.join(__dir__, "patient_http/request_helper")
  autoload :RequestTask, File.join(__dir__, "patient_http/request_task")
  autoload :RequestTemplate, File.join(__dir__, "patient_http/request_template")
  autoload :Response, File.join(__dir__, "patient_http/response")
  autoload :ResponseReader, File.join(__dir__, "patient_http/response_reader")
  autoload :ServerError, File.join(__dir__, "patient_http/http_error")
  autoload :SynchronousExecutor, File.join(__dir__, "patient_http/synchronous_executor")
  autoload :TaskHandler, File.join(__dir__, "patient_http/task_handler")
  autoload :TooManyRedirectsError, File.join(__dir__, "patient_http/redirect_error")

  @testing = ENV["RAILS_ENV"] == "test"
  @handler = nil

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
    # @return [void]
    def register_handler(callable = nil, &block)
      raise ArgumentError.new("Must provide a callable object or a block") unless callable || block_given?
      raise ArgumentError.new("Cannot provide both a callable object and a block") if callable && block_given?

      handler = callable || block
      raise ArgumentError.new("Handler must be a callable object or a block") unless handler.respond_to?(:call)

      validate_handler_parameters!(handler)

      @handler = handler
    end

    # Unregisters the current request handler.
    #
    # @param handler [#call, nil] If provided, only unregisters if the given handler matches
    #   the current handler
    # @return [void]
    def unregister_handler(handler = nil)
      @handler = nil if @handler == handler || handler.nil?
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
      unless @handler
        raise "No request handler registered; you must register a PatientHttp handler before executing requests"
      end

      @handler.call(
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
      callback_args: nil
    )
      request = Request.new(method, url, body: body, json: json, headers: headers, params: params, timeout: timeout)
      execute(
        request: request,
        callback: callback,
        callback_args: callback_args,
        raise_error_responses: raise_error_responses
      )
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
          "#{required_keywords.map(&:to_s).join(", ")}. " \
          "Missing: #{missing_keywords.map(&:to_s).join(", ")}"
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
        "Found: #{extra_required_keywords.map(&:to_s).join(", ")}"
      )
    end
  end
end
