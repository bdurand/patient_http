# frozen_string_literal: true

module PatientHttp
  # A {Request} with the callback service and the task handler that the
  # processor needs to run it. The task tracks the request from enqueue to
  # completion, and delivers the result through its task handler.
  #
  # @example Create a task and enqueue it
  #   task = PatientHttp::RequestTask.new(
  #     request: PatientHttp::Request.new(:get, "https://api.example.com/users/123"),
  #     task_handler: MyTaskHandler.new("job-123"),
  #     callback: "FetchUserCallback",
  #     callback_args: {user_id: 123}
  #   )
  #   processor.enqueue(task)
  class RequestTask
    include TimeHelper

    # The headers that are removed on a cross-origin redirect.
    SENSITIVE_HEADERS = %w[authorization cookie].freeze

    # The headers that describe a request body. They're removed when a redirect
    # drops the body.
    BODY_HEADERS = %w[content-type content-length content-encoding content-language content-location].freeze

    # @return [String] The unique task ID. A task that follows a redirect has
    #   the ID of the original task with a suffix.
    attr_reader :id

    # @return [Request] The HTTP request.
    attr_reader :request

    # @return [TaskHandler] The task handler that delivers the result.
    attr_reader :task_handler

    # @return [String] The callback service class name.
    attr_reader :callback

    # @return [Hash] The callback arguments for the {Response} or {Error}. Never
    #   `nil`.
    attr_reader :callback_args

    # @return [Boolean] Whether non-2xx responses go to the `on_error` callback
    #   as an {HttpError}.
    attr_reader :raise_error_responses

    # @return [Array<String>] The URLs of the redirects that were followed.
    attr_reader :redirects

    # @return [Response, nil] The HTTP response, after the request succeeds.
    attr_reader :response

    # @return [Exception, nil] The error, after the request fails.
    attr_reader :error

    # Creates a task.
    #
    # @param request [Request] The HTTP request.
    # @param task_handler [TaskHandler] The task handler that delivers the
    #   result.
    # @param callback [String, Class] The callback service class, or its name.
    # @param callback_args [Hash] The JSON-compatible arguments to pass to the
    #   callback. The callback reads them from `response.callback_args` or
    #   `error.callback_args`.
    # @param raise_error_responses [Boolean] Whether non-2xx responses go to the
    #   `on_error` callback as an {HttpError}.
    # @param redirects [Array<String>] The URLs of the redirects that were
    #   followed.
    # @param id [String, nil] The unique task ID. If `nil`, a new UUID is
    #   generated.
    # @param default_max_redirects [Integer] The maximum number of redirects to
    #   follow if the request doesn't set one.
    # @raise [ArgumentError] If a required argument is missing, or if the
    #   callback service or callback arguments aren't valid.
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

    # Records the time that the task was enqueued.
    #
    # @return [void]
    def enqueued!
      @enqueued_at = monotonic_time
    end

    # Records the time that the request started.
    #
    # @return [void]
    def started!
      @started_at = monotonic_time
    end

    # Returns whether the request started. The processor uses this value to
    # send `request_end` to observers only for tasks that got `request_start`.
    #
    # @return [Boolean] `true` if {#started!} was called.
    def started?
      !@started_at.nil?
    end

    # Returns the time that the task was enqueued.
    #
    # @return [Time, nil] The time, or `nil` if the task isn't enqueued.
    def enqueued_at
      wall_clock_time(@enqueued_at) if @enqueued_at
    end

    # Returns the time that the request started.
    #
    # @return [Time, nil] The time, or `nil` if the request didn't start.
    def started_at
      wall_clock_time(@started_at) if @started_at
    end

    # Returns the time that the request finished.
    #
    # @return [Time, nil] The time, or `nil` if the request didn't finish.
    def completed_at
      wall_clock_time(@completed_at) if @completed_at
    end

    # Returns the time that the task waited in the queue before the request
    # started.
    #
    # @return [Float, nil] The duration in seconds, or `nil` if the task isn't
    #   enqueued.
    def enqueued_duration
      return nil unless @enqueued_at

      (@started_at || monotonic_time) - @enqueued_at
    end

    # Returns the time that the request ran.
    #
    # @return [Float, nil] The duration in seconds, or `nil` if the request
    #   didn't start.
    def duration
      return nil unless @started_at

      ((@completed_at || monotonic_time) - @started_at).round(9)
    end

    # Re-enqueues the original job through the task handler.
    #
    # @return [String] The new job ID.
    def retry
      @task_handler.retry
    end

    # Records the response, and delivers it through the task handler. The
    # response can have an HTTP error status (4xx or 5xx).
    #
    # @param response [Response] The HTTP response.
    # @return [void]
    def completed!(response)
      @completed_at = monotonic_time
      @response = response

      @task_handler.on_complete(response, @callback)
    end

    # Records the error, and delivers it through the task handler. An exception
    # that isn't an {Error} is wrapped in a {RequestError}.
    #
    # @param exception [Exception] The error.
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

    # Returns whether the server sent a response. The response can have an HTTP
    # error status (4xx or 5xx).
    #
    # @return [Boolean] `true` if a response was received.
    def success?
      !@response.nil?
    end

    # Returns whether the request raised an error.
    #
    # @return [Boolean] `true` if the request failed.
    def error?
      !@error.nil?
    end

    # Returns the maximum number of redirects to follow. The request value
    # applies if it's set. Otherwise, the default applies.
    #
    # @return [Integer] The maximum number of redirects.
    def max_redirects
      request.max_redirects || @default_max_redirects
    end

    # Creates a task that follows a redirect.
    #
    # The HTTP method follows RFC 9110. A 301 or 302 changes POST to GET. A 303
    # changes all methods except GET and HEAD to GET. A 300, 307, or 308 keeps
    # the method. When the method changes, the body and the headers that
    # describe it are removed.
    #
    # The headers named in the request's `redirect_strip_headers` or in
    # `strip_headers` are removed. On a cross-origin redirect, the
    # `Authorization` and `Cookie` headers and the preprocessors are removed.
    #
    # @param location [String] The URL from the `Location` header.
    # @param status [Integer] The HTTP status of the redirect response.
    # @param strip_headers [Array<String>] More header names to remove, usually
    #   from the {Configuration}.
    # @return [RequestTask] The task for the redirect.
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

    # Builds a {Response} for this task.
    #
    # @param status [Integer] The HTTP status code.
    # @param headers [Hash] The response headers.
    # @param body [String, nil] The response body.
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

    # Returns the ID of the first task, before any redirects. Use it to track a
    # request across its redirect tasks.
    #
    # @return [String] The original task ID.
    def original_id
      id.split("/").first
    end

    private

    # Returns whether two URLs have different origins. The origin is the
    # scheme, host, and port.
    #
    # @param original_url [String] The original request URL.
    # @param target_url [String] The redirect URL.
    # @return [Boolean] `true` if the origins are different.
    def cross_origin?(original_url, target_url)
      original = URI.parse(original_url)
      target = URI.parse(target_url)

      original.scheme != target.scheme ||
        original.host != target.host ||
        original.port != target.port
    end

    # Resolves a redirect URL. A relative URL is joined with the request URL.
    #
    # @param location [String] The `Location` header value.
    # @return [String] The absolute URL.
    def resolve_redirect_url(location)
      base_uri = URI.parse(request.url)
      redirect_uri = URI.parse(location)

      return location if redirect_uri.absolute?

      base_uri.merge(redirect_uri).to_s
    end
  end
end
