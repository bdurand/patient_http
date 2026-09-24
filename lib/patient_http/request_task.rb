# frozen_string_literal: true

module PatientHttp
  # Wraps a {Request} with the callback and job context that the {Processor} needs.
  # A request task is enqueued and processed asynchronously. It tracks the request
  # lifecycle and handles success and error callbacks.
  class RequestTask
    include TimeHelper

    # The origin-sensitive headers that are stripped on cross-origin redirects.
    SENSITIVE_HEADERS = %w[authorization cookie].freeze

    # The headers that describe a request body. They're removed when a redirect drops
    # the body.
    BODY_HEADERS = %w[content-type content-length content-encoding content-language content-location].freeze

    # @return [String] The unique UUID for tracking the task.
    attr_reader :id

    # @return [Request] The HTTP request.
    attr_reader :request

    # @return [TaskHandler] The handler for job lifecycle operations.
    attr_reader :task_handler

    # @return [String] The callback class name.
    attr_reader :callback

    # @return [Hash] The callback arguments to include in {Response} and {Error} objects.
    #   Never `nil`. Defaults to an empty hash.
    attr_reader :callback_args

    # @return [Boolean] Whether non-2xx responses raise {HttpError}.
    attr_reader :raise_error_responses

    # @return [Array<String>] The URLs visited in the redirect chain.
    attr_reader :redirects

    # @return [Response, nil] The HTTP response, set on success.
    attr_reader :response

    # @return [Exception, nil] The error, set on failure.
    attr_reader :error

    # Creates a request task.
    #
    # @param request [Request] The HTTP request to wrap.
    # @param task_handler [TaskHandler] The handler for job lifecycle operations.
    # @param callback [String, Class] The callback class or class name.
    # @param callback_args [Hash] The callback arguments, with string keys, to include in
    #   {Response} and {Error} objects. Access them with `response.callback_args` or
    #   `error.callback_args`.
    # @param raise_error_responses [Boolean] Whether non-2xx responses raise {HttpError}.
    # @param redirects [Array<String>] The URLs visited in the redirect chain.
    # @param id [String, nil] The unique UUID for tracking the task. If `nil`, a new UUID is
    #   generated.
    # @param default_max_redirects [Integer] The maximum number of redirects to use when the
    #   request doesn't set one.
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

    # Marks the task as enqueued.
    #
    # @return [void]
    def enqueued!
      @enqueued_at = monotonic_time
    end

    # Marks the task as started.
    #
    # @return [void]
    def started!
      @started_at = monotonic_time
    end

    # Returns `true` if the task started processing, which means {#started!} was
    # called. The processor uses this method to keep the observer `request_start`
    # and `request_end` notifications balanced when a task is re-enqueued during
    # shutdown.
    #
    # @return [Boolean]
    def started?
      !@started_at.nil?
    end

    # Returns the wall clock time when the task was enqueued.
    #
    # @return [Time, nil] The enqueued time, or `nil` if the task isn't enqueued.
    def enqueued_at
      wall_clock_time(@enqueued_at) if @enqueued_at
    end

    # Returns the wall clock time when the task was started.
    #
    # @return [Time, nil] The start time, or `nil` if the task hasn't started.
    def started_at
      wall_clock_time(@started_at) if @started_at
    end

    # Returns the wall clock time when the task was completed.
    #
    # @return [Time, nil] The completion time, or `nil` if the task hasn't completed.
    def completed_at
      wall_clock_time(@completed_at) if @completed_at
    end

    # Returns how long the task was enqueued, in seconds.
    #
    # @return [Float, nil] The duration, or `nil` if the task isn't enqueued yet.
    def enqueued_duration
      return nil unless @enqueued_at

      (@started_at || monotonic_time) - @enqueued_at
    end

    # Returns the execution duration, in seconds.
    #
    # @return [Float, nil] The duration, or `nil` if the task hasn't started yet.
    def duration
      return nil unless @started_at

      ((@completed_at || monotonic_time) - @started_at).round(9)
    end

    # Re-enqueues the original job through the task handler.
    #
    # @return [String] The job ID.
    def retry
      @task_handler.retry
    end

    # Called with the HTTP response when a request completes. The response might
    # have an HTTP error status (4xx or 5xx).
    #
    # @param response [Response] The HTTP response.
    # @return [void]
    def completed!(response)
      @completed_at = monotonic_time
      @response = response

      @task_handler.on_complete(response, @callback)
    end

    # Called with the error when a request fails.
    #
    # @param exception [Exception] The error that occurred.
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

    # Returns `true` if the task received a response from the server. The response
    # might have an HTTP error status (4xx or 5xx).
    #
    # @return [Boolean]
    def success?
      !@response.nil?
    end

    # Returns `true` if an error was raised during the request.
    #
    # @return [Boolean]
    def error?
      !@error.nil?
    end

    # Returns the maximum number of redirects to follow. Uses the request's
    # `max_redirects` if it's set, or the default otherwise.
    #
    # @return [Integer] The maximum number of redirects.
    def max_redirects
      request.max_redirects || @default_max_redirects
    end

    # Creates a request task that follows a redirect.
    #
    # The HTTP method follows RFC 9110. 301 and 302 change `POST` to `GET`. 303
    # changes every method except `GET` and `HEAD` to `GET`. 300, 307, and 308
    # preserve the method. When the method changes, the body and the headers that
    # describe it are dropped.
    #
    # Headers named in the request's `redirect_strip_headers` or in `strip_headers`
    # are removed from the redirected request. On cross-origin redirects, the
    # `Authorization` and `Cookie` headers and the preprocessors are removed.
    #
    # @param location [String] The redirect URL from the `Location` header.
    # @param status [Integer] The HTTP status code of the redirect response.
    # @param strip_headers [Array<String>] Additional header names to strip, usually from
    #   the {Configuration}.
    # @return [RequestTask] A new task configured for the redirect.
    def redirect_task(location:, status:, strip_headers: [])
      redirect_method = RedirectHelper.redirect_method(request.http_method, status)
      method_changed = (redirect_method != request.http_method)
      redirect_body = method_changed ? nil : request.body

      # Resolve the redirect URL (handle relative URLs)
      redirect_url = resolve_redirect_url(location)

      # Strip sensitive headers and preprocessors on cross-origin redirects to
      # prevent credential leakage
      cross_origin = cross_origin?(request.url, redirect_url)
      redirect_headers = cross_origin ? request.headers.except(*SENSITIVE_HEADERS) : request.headers
      redirect_headers = redirect_headers.except(*BODY_HEADERS) if method_changed
      redirect_preprocessors = cross_origin ? [] : request.preprocessors

      strip_names = request.redirect_strip_headers + Array(strip_headers)
      redirect_headers = redirect_headers.except(*strip_names) if strip_names.any?

      # Create a new request for the redirect
      redirect_request = Request.new(
        redirect_method,
        redirect_url,
        headers: redirect_headers,
        body: redirect_body,
        timeout: request.timeout,
        max_redirects: request.max_redirects,
        follow_method_changing_redirects: request.follow_method_changing_redirects,
        redirect_strip_headers: request.redirect_strip_headers,
        preprocessors: redirect_preprocessors,
        processor: request.processor
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

    # Builds a {Response} from response data.
    #
    # @param status [Integer] The HTTP status code.
    # @param headers [Hash] The HTTP response headers.
    # @param body [String, nil] The HTTP response body.
    # @return [Response] The response.
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

    # Returns the ID of the first request task, before any redirects. Use this ID to
    # track the overall request across redirect tasks.
    #
    # @return [String] The original request ID.
    def original_id
      id.split("/").first
    end

    private

    # Returns `true` if two URLs have different origins. An origin is the scheme,
    # host, and port.
    #
    # @param original_url [String] The original request URL.
    # @param target_url [String] The redirect target URL.
    # @return [Boolean] `true` if the origins differ.
    def cross_origin?(original_url, target_url)
      original = URI.parse(original_url)
      target = URI.parse(target_url)

      original.scheme != target.scheme ||
        original.host != target.host ||
        original.port != target.port
    end

    # Resolves a redirect URL, including a relative URL, to an absolute URL.
    #
    # @param location [String] The `Location` header value.
    # @return [String] The resolved absolute URL.
    def resolve_redirect_url(location)
      base_uri = URI.parse(request.url)
      redirect_uri = URI.parse(location)

      return location if redirect_uri.absolute?

      base_uri.merge(redirect_uri).to_s
    end
  end
end
