# frozen_string_literal: true

module PatientHttp
  # Runs a request synchronously on the calling thread, and then calls the
  # callback service.
  #
  # Use it in tests, and wherever a request must run inline. It doesn't depend
  # on module-level state: you give it the configuration and optional hooks.
  #
  # The request uses a {ClientPool} that exists only for this call. The
  # connection timeout, TCP settings, protocol, proxy, and retry rules are the
  # same as for requests on a processor.
  #
  # @example Run a request
  #   executor = PatientHttp::SynchronousExecutor.new(
  #     task,
  #     config: config,
  #     on_complete: ->(response) { StatsD.increment("complete") },
  #     on_error: ->(error) { StatsD.increment("error") }
  #   )
  #   executor.call
  class SynchronousExecutor
    include RedirectHelper
    include ImmediateRetries

    # Creates an executor.
    #
    # @param task [RequestTask] The task to run.
    # @param config [Configuration] The configuration for the request.
    # @param on_complete [Proc, nil] A hook that runs with the response before
    #   the callback service's `on_complete` method.
    # @param on_error [Proc, nil] A hook that runs with the error before the
    #   callback service's `on_error` method.
    def initialize(task, config:, on_complete: nil, on_error: nil)
      @task = task
      @config = config
      @on_complete = on_complete
      @on_error = on_error
      @request_preparer = RequestPreparer.new(config)
      @response_reader = ResponseReader.new(nil, config: config)
      @client_pool = ClientPool.from_config(config)
    end

    # Runs the request, and then calls the hook and the callback service with
    # the response or error.
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

    # Sends the request of the current task and reads the full response.
    #
    # {ResponseReader} decodes the body. A `Protocol::HTTP::AcceptEncoding`
    # wrapper isn't used, because it replaces an `accept-encoding` header that
    # the caller set to turn off compression.
    #
    # @return [Hash] The response data, with the `:status`, `:headers`, and
    #   `:body` keys.
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

    # Calls the hook and the callback service with a result.
    #
    # @param result [Response, Error] The result.
    # @param type [Symbol] `:response` or `:error`.
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
