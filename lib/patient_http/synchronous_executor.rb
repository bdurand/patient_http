# frozen_string_literal: true

module PatientHttp
  # Executes HTTP requests synchronously, inline in the current thread.
  #
  # Use this class in tests or wherever you need synchronous execution. It takes a
  # configuration and optional callback hooks, so it doesn't depend on any
  # module-level state.
  #
  # Connections go through a {ClientPool} that exists only for this execution. The
  # connection timeout, TCP socket settings, protocol, proxy, and immediate retry
  # rules apply the same way they do for asynchronous requests.
  class SynchronousExecutor
    include RedirectHelper
    include ImmediateRetries

    # Creates an executor for a request task.
    #
    # @param task [RequestTask] The request task to execute.
    # @param config [Configuration] The pool configuration.
    # @param on_complete [Proc, nil] A hook that is called with the response on success.
    # @param on_error [Proc, nil] A hook that is called with the error on failure.
    def initialize(task, config:, on_complete: nil, on_error: nil)
      @task = task
      @config = config
      @on_complete = on_complete
      @on_error = on_error
      @request_preparer = RequestPreparer.new(config)
      @response_reader = ResponseReader.new(nil, config: config)
      @client_pool = ClientPool.from_config(config)
    end

    # Executes the request synchronously.
    #
    # @return [void]
    def call
      Async do
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          response_data = nil
          redirect_error = nil

          loop do
            response_data = perform_request

            # Check for redirect
            break unless should_follow_redirect?(@task, response_data)

            # Note: a `return` here would raise LocalJumpError since this block
            # runs on a reactor fiber, so break out and handle the error below.
            redirect_error = check_redirect_error(@task, response_data)
            break if redirect_error

            @task = build_redirect_task(@task, response_data)
          end

          if redirect_error
            invoke_callback(redirect_error, :error)
          else
            end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            duration = end_time - start_time

            response = Response.new(
              status: response_data[:status],
              headers: response_data[:headers],
              body: response_data[:body],
              duration: duration,
              request_id: @task.original_id,
              url: @task.request.url,
              http_method: @task.request.http_method,
              callback_args: @task.callback_args,
              redirects: @task.redirects
            )

            if @task.raise_error_responses && !response.success?
              http_error = HttpError.new(response)
              invoke_callback(http_error, :error)
            else
              invoke_callback(response, :response)
            end
          end
        rescue => e
          end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          duration = end_time - start_time

          error = RequestError.from_exception(
            e,
            request_id: @task.id,
            duration: duration,
            url: @task.request.url,
            http_method: @task.request.http_method,
            callback_args: @task.callback_args
          )
          invoke_callback(error, :error)
        ensure
          @client_pool.close
        end
      end
    end

    private

    attr_reader :config

    # Sends the current task's request and reads the whole response.
    #
    # {ResponseReader} decodes response bodies. A `Protocol::HTTP::AcceptEncoding`
    # wrapper isn't used, because it would overwrite an `accept-encoding` header
    # that a caller sets to turn off compression.
    #
    # @return [Hash] The response data with the keys `:status`, `:headers`, and `:body`.
    def perform_request
      outgoing = @request_preparer.prepare(@task.request, @task.id)
      timeout = @task.request.timeout || @config.request_timeout

      Async::Task.current.with_timeout(timeout) do
        headers = outgoing.headers.to_h
        body = Protocol::HTTP::Body::Buffered.wrap([@task.request.body.to_s]) if @task.request.body

        endpoint = Async::HTTP::Endpoint.parse(outgoing.url)
        async_response = request_with_immediate_retries(
          @client_pool, @task.request, endpoint, headers, body
        )
        # Note: headers that appear multiple times (e.g. set-cookie) are
        # flattened to a single joined string value.
        headers_hash = async_response.headers.to_h.transform_values(&:to_s)

        chunks = @response_reader.read_raw_body(async_response, headers_hash)
        body_content = @response_reader.decode_body(chunks, headers_hash)

        {
          status: async_response.status,
          headers: ResponseReader.rewrite_content_encoding(headers_hash),
          body: body_content
        }
      end
    end

    # Invokes the callback synchronously.
    #
    # @param result [Response, Error] The result to pass to the callback.
    # @param type [Symbol] Either `:response` or `:error`.
    def invoke_callback(result, type)
      callback_class = @task.callback.is_a?(Class) ? @task.callback : ClassHelper.resolve_class_name(@task.callback)
      callback = callback_class.new

      if type == :response
        @on_complete&.call(result)
        callback.on_complete(result)
      else
        @on_error&.call(result)
        callback.on_error(result)
      end
    end
  end
end
