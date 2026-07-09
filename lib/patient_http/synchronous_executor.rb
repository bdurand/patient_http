# frozen_string_literal: true

module PatientHttp
  # Handles synchronous/inline execution of HTTP requests.
  #
  # Used for testing or when synchronous execution is needed.
  # Accepts configuration and optional callback hooks so it has
  # no dependency on any module-level singleton state.
  class SynchronousExecutor
    include RedirectHelper

    # @param task [RequestTask] the request task to execute
    # @param config [Configuration] the pool configuration
    # @param on_complete [Proc, nil] hook called with response on success
    # @param on_error [Proc, nil] hook called with error on failure
    def initialize(task, config:, on_complete: nil, on_error: nil)
      @task = task
      @config = config
      @on_complete = on_complete
      @on_error = on_error
      @proxy_client = nil
      @request_preparer = RequestPreparer.new(config)
    end

    # Execute the request synchronously.
    # @return [void]
    def call
      Async do
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          http_client = nil
          response_data = nil
          redirect_error = nil

          loop do
            http_client&.close
            @proxy_client&.close
            @proxy_client = nil
            outgoing = @request_preparer.prepare(@task.request, @task.id)
            http_client = create_http_client(outgoing.url)
            timeout = @task.request.timeout || @config.request_timeout

            response_data = Async::Task.current.with_timeout(timeout) do
              headers = outgoing.headers.to_h
              body = Protocol::HTTP::Body::Buffered.wrap([@task.request.body.to_s]) if @task.request.body

              endpoint = Async::HTTP::Endpoint.parse(outgoing.url)
              endpoint = configure_endpoint(endpoint) if @config.connection_timeout

              verb = @task.request.http_method.to_s.upcase
              options = {
                headers: headers,
                body: body,
                scheme: endpoint.scheme,
                authority: endpoint.authority
              }

              request = Protocol::HTTP::Request[verb, endpoint.path, **options]
              async_response = http_client.call(request)
              # Note: headers that appear multiple times (e.g. set-cookie) are
              # flattened to a single joined string value.
              headers_hash = async_response.headers.to_h.transform_values(&:to_s)

              body_content = read_response_body(async_response, headers_hash)

              {
                status: async_response.status,
                headers: headers_hash,
                body: body_content
              }
            end

            # Check for redirect
            break unless should_follow_redirect?(@task, response_data)

            # Note: a `return` here would raise LocalJumpError since this block
            # runs on a reactor fiber, so break out and handle the error below.
            redirect_error = check_redirect_error(@task, response_data)
            break if redirect_error

            location = response_data[:headers]["location"]
            @task = @task.redirect_task(location: location, status: response_data[:status])
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
          http_client&.close
          @proxy_client&.close
          @proxy_client = nil
        end
      end
    end

    private

    # Create HTTP client with config settings (retries, proxy, connection timeout).
    #
    # @param url [String] the resolved request URL
    # @return [Protocol::HTTP::AcceptEncoding] wrapped HTTP client
    def create_http_client(url)
      endpoint = Async::HTTP::Endpoint.parse(url)
      endpoint = configure_endpoint(endpoint) if @config.connection_timeout

      client = if @config.proxy_url
        create_proxied_client(endpoint)
      else
        Async::HTTP::Client.new(endpoint, retries: @config.retries)
      end

      Protocol::HTTP::AcceptEncoding.new(client)
    end

    # Create a proxied HTTP client.
    #
    # @param endpoint [Async::HTTP::Endpoint] the target endpoint
    # @return [Async::HTTP::Client] the proxied client
    def create_proxied_client(endpoint)
      require "async/http/proxy"

      proxy_endpoint = Async::HTTP::Endpoint.parse(@config.proxy_url)
      proxy_endpoint = configure_endpoint(proxy_endpoint) if @config.connection_timeout
      @proxy_client = Async::HTTP::Client.new(proxy_endpoint)

      proxy = @proxy_client.proxy(endpoint)
      Async::HTTP::Client.new(proxy.wrap_endpoint(endpoint), retries: @config.retries)
    end

    # Configure endpoint with connection timeout if specified.
    #
    # @param endpoint [Async::HTTP::Endpoint] the endpoint to configure
    # @return [Async::HTTP::Endpoint] the configured endpoint
    def configure_endpoint(endpoint)
      Async::HTTP::Endpoint.new(
        endpoint.url,
        timeout: @config.connection_timeout
      )
    end

    # Read the response body with size validation.
    #
    # @param async_response [Async::HTTP::Protocol::Response] the async HTTP response
    # @param headers_hash [Hash] the response headers
    # @return [String, nil] the response body
    def read_response_body(async_response, headers_hash)
      return nil unless async_response.body

      content_length = headers_hash["content-length"]&.to_i
      if content_length && content_length > @config.max_response_size
        raise ResponseTooLargeError.new(
          "Response body size (#{content_length} bytes) exceeds maximum allowed size (#{@config.max_response_size} bytes)"
        )
      end

      chunks = []
      total_size = 0
      finished = false

      begin
        async_response.body.each do |chunk|
          total_size += chunk.bytesize
          if total_size > @config.max_response_size
            raise ResponseTooLargeError.new(
              "Response body size exceeded maximum allowed size (#{@config.max_response_size} bytes)"
            )
          end
          chunks << chunk
        end

        finished = true
      ensure
        # Close the body if the read was interrupted so the connection is released
        async_response.body.close unless finished
      end

      body = chunks.join.force_encoding(Encoding::ASCII_8BIT)

      charset = extract_charset(headers_hash)
      if charset
        begin
          encoding = Encoding.find(charset)
          body.force_encoding(encoding)
        rescue ArgumentError
          # Invalid charset, keep binary
        end
      end

      body
    end

    # Extract charset from Content-Type header.
    def extract_charset(headers_hash)
      content_type = headers_hash["content-type"]
      return nil unless content_type

      match = content_type.match(/;\s*charset\s*=\s*([^;\s]+)/i)
      return nil unless match

      charset = match[1].strip
      charset.gsub(/\A["']|["']\z/, "")
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
