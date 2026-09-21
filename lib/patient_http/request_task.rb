# frozen_string_literal: true

module PatientHttp
  # A wrapper around {Request} that adds the callback and job context that the
  # {Processor} needs.
  #
  # This class lets the processor enqueue and run HTTP requests asynchronously. It
  # tracks the lifecycle of a request and handles the success and error callbacks.
  class RequestTask
    include TimeHelper

    # Headers that depend on the origin. They are stripped on a cross-origin redirect.
    SENSITIVE_HEADERS = %w[authorization cookie].freeze

    # Headers that describe a request body. They are removed when a redirect drops the
    # body.
    BODY_HEADERS = %w[content-type content-length content-encoding content-language content-location].freeze

    # @return [String] The unique UUID that tracks the task.
    attr_reader :id

    # @return [Request] The HTTP request.
    attr_reader :request

    # @return [TaskHandler] The handler for the job lifecycle operations.
    attr_reader :task_handler

    # @return [String] The class name of the callback service.
    attr_reader :callback

    # @return [Hash] The callback arguments to include in the {Response} and {Error}
    #   objects. The value is never nil, and it defaults to an empty hash.
    attr_reader :callback_args

    # @return [Boolean] Whether to raise an {HttpError} for a non-2xx response.
    attr_reader :raise_error_responses

    # @return [Array<String>] The URLs that were visited in the redirect chain.
    attr_reader :redirects

    # @return [Response, nil] The HTTP response, which is set on success.
    attr_reader :response

    # @return [Exception, nil] The error, which is set on failure.
    attr_reader :error

    # Initializes a new RequestTask.
    #
    # @param request [Request] The HTTP request to wrap.
    # @param task_handler [TaskHandler] The handler for the job lifecycle operations.
    # @param callback [String, Class] The callback service class, or its name.
    # @param callback_args [Hash] The callback arguments, with string keys, to include
    #   in the {Response} and {Error} objects. You can read them with
    #   `response.callback_args` and `error.callback_args`.
    # @param raise_error_responses [Boolean] Whether to raise an {HttpError} for a
    #   non-2xx response.
    # @param redirects [Array<String>] The URLs that were visited in the redirect
    #   chain.
    # @param id [String, nil] The unique UUID that tracks the task. If nil, a new UUID
    #   is generated.
    # @param default_max_redirects [Integer] The number of redirects to allow when the
    #   request does not set its own limit.
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

    # Checks whether the task has started processing, that is, whether {#started!} was
    # called. This keeps the `request_start` and `request_end` notifications to the
    # observers balanced when a task is re-enqueued during a shutdown.
    #
    # @return [Boolean] Whether the task has started.
    def started?
      !@started_at.nil?
    end

    # Returns the wall clock time when the task was enqueued.
    #
    # @return [Time, nil] The time when the task was enqueued, or nil if it is not
    #   enqueued.
    def enqueued_at
      wall_clock_time(@enqueued_at) if @enqueued_at
    end

    # Returns the wall clock time when the task started.
    #
    # @return [Time, nil] The time when the task started, or nil if it has not
    #   started.
    def started_at
      wall_clock_time(@started_at) if @started_at
    end

    # Returns the wall clock time when the task completed.
    #
    # @return [Time, nil] The time when the task completed, or nil if it has not
    #   completed.
    def completed_at
      wall_clock_time(@completed_at) if @completed_at
    end

    # Returns how long the task has been enqueued.
    #
    # @return [Float, nil] The duration in seconds, or nil if the task is not enqueued
    #   yet.
    def enqueued_duration
      return nil unless @enqueued_at

      (@started_at || monotonic_time) - @enqueued_at
    end

    # Returns how long the task has been running.
    #
    # @return [Float, nil] The duration in seconds, or nil if the task has not started
    #   yet.
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

    # Called with the HTTP response of a completed request. The response can hold an
    # HTTP error status, either 4xx or 5xx.
    #
    # @param response [Response] The HTTP response.
    # @return [void]
    def completed!(response)
      @completed_at = monotonic_time
      @response = response

      @task_handler.on_complete(response, @callback)
    end

    # Called with the error of a failed request.
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

    # Checks whether the task received a response from the server. The response can
    # hold an HTTP error status, either 4xx or 5xx.
    #
    # @return [Boolean] Whether a response was received.
    def success?
      !@response.nil?
    end

    # Checks whether an error was raised during the request.
    #
    # @return [Boolean] Whether an error was raised.
    def error?
      !@error.nil?
    end

    # Returns the maximum number of redirects to follow. This is the `max_redirects`
    # value of the request, or the default value when the request does not set one.
    #
    # @return [Integer] The maximum number of redirects.
    def max_redirects
      request.max_redirects || @default_max_redirects
    end

    # Creates a new RequestTask that follows a redirect.
    #
    # The HTTP method follows RFC 9110: 301 and 302 change POST to GET, 303 changes
    # every method except GET and HEAD to GET, and 300, 307, and 308 keep the method.
    # The body, and the headers that describe it, are dropped whenever the method
    # changes.
    #
    # The headers that the `redirect_strip_headers` value of the request names, and
    # the headers in the given list, are removed from the redirected request. The
    # Authorization and Cookie headers, and the preprocessors, are removed on a
    # cross-origin redirect.
    #
    # @param location [String] The redirect URL from the Location header.
    # @param status [Integer] The HTTP status code of the redirect response.
    # @param strip_headers [Array<String>] Additional header names to strip, usually
    #   from the {Configuration}.
    # @return [RequestTask] A new task for the redirect.
    def redirect_task(location:, status:, strip_headers: [])
      redirect_method = RedirectHelper.redirect_method(request.http_method, status)
      method_changed = (redirect_method != request.http_method)
      redirect_body = method_changed ? nil : request.body

      # Resolve the redirect URL, which can be relative.
      redirect_url = resolve_redirect_url(location)

      # Strip the sensitive headers and the preprocessors on a cross-origin redirect,
      # so that credentials cannot leak.
      cross_origin = cross_origin?(request.url, redirect_url)
      redirect_headers = cross_origin ? request.headers.except(*SENSITIVE_HEADERS) : request.headers
      redirect_headers = redirect_headers.except(*BODY_HEADERS) if method_changed
      redirect_preprocessors = cross_origin ? [] : request.preprocessors

      strip_names = request.redirect_strip_headers + Array(strip_headers)
      redirect_headers = redirect_headers.except(*strip_names) if strip_names.any?

      # Create a new request for the redirect.
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

      # Create the new task with the updated redirect chain.
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

    # Builds a {Response} from async response data.
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
    # track the whole request across several redirect tasks.
    #
    # @return [String] The original request ID.
    def original_id
      id.split("/").first
    end

    private

    # Checks whether two URLs have different origins. An origin is the combination of
    # the scheme, the host, and the port.
    #
    # @param original_url [String] The original request URL.
    # @param target_url [String] The redirect target URL.
    # @return [Boolean] Whether the origins are different.
    def cross_origin?(original_url, target_url)
      original = URI.parse(original_url)
      target = URI.parse(target_url)

      original.scheme != target.scheme ||
        original.host != target.host ||
        original.port != target.port
    end

    # Resolves a redirect URL, including a relative URL.
    #
    # @param location [String] The Location header value.
    # @return [String] The resolved absolute URL.
    def resolve_redirect_url(location)
      base_uri = URI.parse(request.url)
      redirect_uri = URI.parse(location)

      return location if redirect_uri.absolute?

      base_uri.merge(redirect_uri).to_s
    end
  end
end
