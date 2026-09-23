# frozen_string_literal: true

module PatientHttp
  # Handles synchronous/inline execution of HTTP requests.
  #
  # Used for testing or when synchronous execution is needed.
  # Accepts configuration and optional callback hooks so it has
  # no dependency on any module-level singleton state.
  #
  # Connections are made through a {ClientPool} that lives for the one
  # execution, so the connection timeout, TCP socket settings, protocol, proxy,
  # and immediate retry rules apply exactly as they do on the async path.
  class SynchronousExecutor
    include RedirectHelper
    include ImmediateRetries

    # @param task [RequestTask] the request task to execute
    # @param config [Configuration] the pool configuration
    # @param on_complete [Proc, nil] hook called with response on success
    # @param on_error [Proc, nil] hook called with error on failure
    def initialize(task, config:, on_complete: nil, on_error: nil)
      @task = task
      @config = config
      @on_complete = on_complete
      @on_error = on_error
      @request_preparer = RequestPreparer.new(config)
      @response_reader = ResponseReader.new(nil, config: config)
      @client_pool = ClientPool.new(
        max_size: config.connection_pool_size,
        connection_timeout: config.connection_timeout,
        proxy_url: config.proxy_url,
        retries: config.retries,
        protocol: config.protocol,
        connection_limit: config.max_connections_per_host,
        tcp_keepalive: config.tcp_keepalive,
        tcp_user_timeout: config.tcp_user_timeout
      )
    end

    # Execute the request synchronously.
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

    # Send the current task's request and read the whole response.
    #
    # Response bodies are decoded by ResponseReader rather than by a
    # Protocol::HTTP::AcceptEncoding wrapper, which would overwrite an
    # accept-encoding header set by a caller opting out of compression.
    #
    # @return [Hash] the response data with keys for :status, :headers, and :body
    def perform_request
      outgoing = @request_preparer.prepare(@task.request, @task.id)
      timeout = @task.request.timeout || @config.request_timeout

      Async::Task.current.with_timeout(timeout) do
        headers = outgoing.headers.to_h
        body = Protocol::HTTP::Body::Buffered.wrap([@task.request.body.to_s]) if @task.request.body

        async_response = request_with_immediate_retries(@client_pool, @task.request, outgoing.url, headers, body)
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

    # Invoke callback synchronously.
    #
    # @param result [Response, Error] the result to pass to callback
    # @param type [Symbol] :response or :error
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
