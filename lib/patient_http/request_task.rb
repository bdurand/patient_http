# frozen_string_literal: true

module PatientHttp
  # A wrapper around {Request} that includes callback and job context for the Processor.
  # This class allows HTTP requests to be enqueued and processed asynchronously,
  # tracking their lifecycle and providing methods to handle success and error callbacks.
  class RequestTask
    include TimeHelper

    # Headers that are sensitive to origin and should be stripped on cross-origin redirects
    SENSITIVE_HEADERS = %w[authorization cookie].freeze

    # @return [String] Unique UUID for tracking the task
    attr_reader :id

    # @return [Request] The HTTP request details
    attr_reader :request

    # @return [TaskHandler] The handler for job lifecycle operations
    attr_reader :task_handler

    # @return [String] Class name for the callback service
    attr_reader :callback

    # @return [Hash] Callback arguments to include in Response/Error objects (never nil, defaults to empty hash)
    attr_reader :callback_args

    # @return [Boolean] Whether to raise HttpError for non-2xx responses
    attr_reader :raise_error_responses

    # @return [Array<String>] URLs visited during redirect chain
    attr_reader :redirects

    # @return [Response, nil] The HTTP response, set on success
    attr_reader :response

    # @return [Exception, nil] The error, set on failure
    attr_reader :error

    # Initializes a new RequestTask.
    #
    # @param request [Request] The HTTP request to wrap.
    # @param task_handler [TaskHandler] The handler for job lifecycle operations.
    # @param callback [String, Class] Class name or class for the callback service.
    # @param callback_args [Hash] Callback arguments (with string keys) to include
    #   in Response/Error objects. These will be accessible via response.callback_args
    #   or error.callback_args.
    # @param raise_error_responses [Boolean] Whether to raise HttpError for non-2xx responses.
    # @param redirects [Array<String>] URLs visited during redirect chain.
    # @param id [String, nil] Unique UUID for tracking the task. If nil, a new UUID will be generated.
    # @param default_max_redirects [Integer] Fallback max_redirects when request doesn't specify one.
    def initialize(
      request:,
      task_handler:,
      callback:,
      callback_args: {},
      raise_error_responses: false,
      redirects: [],
      id: nil,
      default_max_redirects: 5
    )
      @id = id&.to_s || SecureRandom.uuid
      @request = request
      @task_handler = task_handler
      @callback = callback.is_a?(Class) ? callback.name : callback.to_s
      @callback_args = CallbackValidator.validate_callback_args(callback_args) || {}
      @raise_error_responses = raise_error_responses
      @redirects = redirects || []
      @default_max_redirects = default_max_redirects

      @enqueued_at = nil
      @started_at = nil
      @completed_at = nil
      @response = nil
      @error = nil

      raise ArgumentError, "request is required" unless @request
      raise ArgumentError, "task_handler is required" unless @task_handler
      raise ArgumentError, "callback is required" if @callback.nil? || @callback.empty?
      CallbackValidator.validate!(@callback)
    end

    # Mark task as enqueued
    # @return [void]
    def enqueued!
      @enqueued_at = monotonic_time
    end

    # Mark task as started
    # @return [void]
    def started!
      @started_at = monotonic_time
    end

    # Return true if the task has started processing (i.e. {#started!} was
    # called). Used to keep observer request_start/request_end notifications
    # balanced when a task is re-enqueued during shutdown.
    #
    # @return [Boolean]
    def started?
      !@started_at.nil?
    end

    # Returns the wall clock time when the task was enqueued.
    #
    # @return [Time, nil] The enqueued time or nil if not enqueued.
    def enqueued_at
      wall_clock_time(@enqueued_at) if @enqueued_at
    end

    # Returns the wall clock time when the task was started.
    #
    # @return [Time, nil] The started time or nil if not started.
    def started_at
      wall_clock_time(@started_at) if @started_at
    end

    # Returns the wall clock time when the task was completed.
    #
    # @return [Time, nil] The completed time or nil if not completed.
    def completed_at
      wall_clock_time(@completed_at) if @completed_at
    end

    # Enqueued duration in seconds.
    # @return [Float, nil] duration or nil if not enqueued yet.
    def enqueued_duration
      return nil unless @enqueued_at

      (@started_at || monotonic_time) - @enqueued_at
    end

    # Execution duration in seconds.
    # @return [Float, nil] duration or nil if not started yet.
    def duration
      return nil unless @started_at

      ((@completed_at || monotonic_time) - @started_at).round(9)
    end

    # Re-enqueue the original job via the task handler.
    # @return [String] job ID
    def retry
      @task_handler.retry
    end

    # Called with the HTTP response on a completed request. Note that
    # the response may represent an HTTP error (4xx or 5xx status).
    #
    # @param response [Response] the HTTP response
    # @return [void]
    def completed!(response)
      @completed_at = monotonic_time
      @response = response

      @task_handler.on_complete(response, @callback)
    end

    # Called with the HTTP error on a failed request.
    #
    # @param exception [Exception] the error that occurred
    # @return [void]
    def error!(exception)
      @completed_at = monotonic_time
      @error = exception

      wrapped_error = exception
      unless wrapped_error.is_a?(Error)
        wrapped_error = RequestError.from_exception(
          exception,
          request_id: @id,
          duration: duration,
          url: request.url,
          http_method: request.http_method,
          callback_args: @callback_args
        )
      end

      @task_handler.on_error(wrapped_error, @callback)
    end

    # Return true if the task successfully received a response from the server.
    # Note that the response may represent an HTTP error (4xx or 5xx status).
    #
    # @return [Boolean]
    def success?
      !@response.nil?
    end

    # Return true if an error was raised during the request.
    #
    # @return [Boolean]
    def error?
      !@error.nil?
    end

    # Returns the maximum number of redirects to follow.
    # Uses the request's max_redirects if set, otherwise falls back to the default.
    #
    # @return [Integer] maximum number of redirects
    def max_redirects
      request.max_redirects || @default_max_redirects
    end

    # Create a new RequestTask for following a redirect.
    #
    # @param location [String] The redirect URL from the Location header
    # @param status [Integer] The HTTP status code of the redirect response
    # @return [RequestTask] A new task configured for the redirect
    def redirect_task(location:, status:)
      # Determine the HTTP method and body for the redirect
      # 301, 302, 303: Convert to GET (no body) - standard browser behavior
      # 307, 308: Preserve original method and body
      if [301, 302, 303].include?(status)
        redirect_method = :get
        redirect_body = nil
      else
        redirect_method = request.http_method
        redirect_body = request.body
      end

      # Resolve the redirect URL (handle relative URLs)
      redirect_url = resolve_redirect_url(location)

      # Strip sensitive headers and preprocessors on cross-origin redirects to
      # prevent credential leakage
      cross_origin = cross_origin?(request.url, redirect_url)
      redirect_headers = cross_origin ? request.headers.except(*SENSITIVE_HEADERS) : request.headers
      redirect_preprocessors = cross_origin ? [] : request.preprocessors

      # Create a new request for the redirect
      redirect_request = Request.new(
        redirect_method,
        redirect_url,
        headers: redirect_headers,
        body: redirect_body,
        timeout: request.timeout,
        max_redirects: request.max_redirects,
        preprocessors: redirect_preprocessors
      )

      redirect_task_id = "#{id.split("/").first}/#{@redirects.size + 2}"

      # Create the new task with updated redirects chain
      self.class.new(
        request: redirect_request,
        task_handler: @task_handler,
        callback: @callback,
        callback_args: @callback_args,
        raise_error_responses: @raise_error_responses,
        redirects: @redirects + [request.url],
        id: redirect_task_id,
        default_max_redirects: @default_max_redirects
      )
    end

    # Build a Response object from async response data.
    #
    # @param status [Integer] HTTP status code
    # @param headers [Hash] HTTP response headers
    # @param body [String, nil] HTTP response body
    # @return [Response] the response object
    # @api private
    def build_response(status:, headers:, body:)
      original_id = id.split("/").first

      Response.new(
        status: status,
        headers: headers,
        body: body,
        duration: duration,
        request_id: original_id,
        url: request.url,
        http_method: request.http_method,
        callback_args: @callback_args,
        redirects: @redirects
      )
    end

    # Get the id of the first request task before any redirects. This is useful for tracking
    # the overall request across multiple redirect tasks.
    #
    # @return [String] the original request id
    def original_id
      id.split("/").first
    end

    private

    # Check if two URLs have different origins (scheme + host + port).
    #
    # @param original_url [String] The original request URL
    # @param target_url [String] The redirect target URL
    # @return [Boolean] true if the origins differ
    def cross_origin?(original_url, target_url)
      original = URI.parse(original_url)
      target = URI.parse(target_url)

      original.scheme != target.scheme ||
        original.host != target.host ||
        original.port != target.port
    end

    # Resolve a redirect URL, handling relative URLs.
    #
    # @param location [String] The Location header value
    # @return [String] The resolved absolute URL
    def resolve_redirect_url(location)
      base_uri = URI.parse(request.url)
      redirect_uri = URI.parse(location)

      return location if redirect_uri.absolute?

      base_uri.merge(redirect_uri).to_s
    end
  end
end
