# frozen_string_literal: true

module PatientHttp
  # Handles synchronous/inline execution of HTTP requests.
  #
  # Used for testing or when synchronous execution is needed.
  # Accepts configuration and optional callback hooks so it has
  # no dependency on any module-level singleton state.
  class SynchronousExecutor
    # @param task [RequestTask] the request task to execute
    # @param config [Configuration] the pool configuration
    # @param on_complete [Proc, nil] hook called with response on success
    # @param on_error [Proc, nil] hook called with error on failure
    def initialize(task, config:, on_complete: nil, on_error: nil)
      @task = task
      @config = config
      @on_complete = on_complete
      @on_error = on_error
    end

    # Execute the request synchronously.
    # @return [void]
    def call
      Async do
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        begin
          http_client = nil
          response_data = nil

          loop do
            http_client&.close
            http_client = create_http_client
            timeout = @task.request.timeout || @config.request_timeout

            response_data = Async::Task.current.with_timeout(timeout) do
              headers = @task.request.headers.to_h.merge("x-request-id" => @task.id)
              headers["user-agent"] ||= @config.user_agent if @config.user_agent
              body = Protocol::HTTP::Body::Buffered.wrap([@task.request.body.to_s]) if @task.request.body

              endpoint = Async::HTTP::Endpoint.parse(@task.request.url)
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

            redirect_error = check_redirect_error(@task, response_data)
            if redirect_error
              invoke_callback(redirect_error, :error)
              return
            end

            location = response_data[:headers]["location"]
            @task = @task.redirect_task(location: location, status: response_data[:status])
          end

          end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          duration = end_time - start_time

          response = Response.new(
            status: response_data[:status],
            headers: response_data[:headers],
            body: response_data[:body],
            duration: duration,
            request_id: @task.id,
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
        end
      end
    end

    private

    # Create HTTP client with config settings (retries, proxy, connection timeout).
    #
    # @return [Protocol::HTTP::AcceptEncoding] wrapped HTTP client
    def create_http_client
      endpoint = Async::HTTP::Endpoint.parse(@task.request.url)
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
      proxy_client = Async::HTTP::Client.new(proxy_endpoint)

      proxy = proxy_client.proxy(endpoint)
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

      async_response.body.each do |chunk|
        total_size += chunk.bytesize
        if total_size > @config.max_response_size
          raise ResponseTooLargeError.new(
            "Response body size exceeded maximum allowed size (#{@config.max_response_size} bytes)"
          )
        end
        chunks << chunk
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

    # Check if a redirect response should be followed.
    #
    # @param task [RequestTask] the request task
    # @param response_data [Hash] the response data with status, headers, body
    # @return [Boolean] true if the redirect should be followed
    def should_follow_redirect?(task, response_data)
      status = response_data[:status]
      return false unless FOLLOWABLE_REDIRECT_STATUSES.include?(status)
      return false if task.max_redirects == 0

      location = response_data[:headers]["location"]
      return false if location.nil? || location.empty?

      true
    end

    # Check for redirect errors (too many redirects or recursive redirect).
    #
    # @param task [RequestTask] the request task
    # @param response_data [Hash] the response data
    # @return [RedirectError, nil] error if redirect should not proceed, nil otherwise
    def check_redirect_error(task, response_data)
      location = response_data[:headers]["location"]
      redirect_url = resolve_redirect_url(task.request.url, location)

      check_too_many_redirects(task, location) || check_recursive_redirect(task, redirect_url)
    end

    # Check if the redirect count has exceeded the maximum.
    #
    # @param task [RequestTask] the request task
    # @param location [String] the redirect location URL
    # @return [TooManyRedirectsError, nil] error if exceeded, nil otherwise
    def check_too_many_redirects(task, location)
      return nil if task.redirects.size < task.max_redirects

      TooManyRedirectsError.new(
        url: location,
        http_method: task.request.http_method,
        duration: nil,
        request_id: task.id,
        redirects: task.redirects + [task.request.url],
        callback_args: task.callback_args
      )
    end

    # Check if the redirect URL has already been visited (redirect loop).
    #
    # @param task [RequestTask] the request task
    # @param redirect_url [String] the resolved redirect URL
    # @return [RecursiveRedirectError, nil] error if loop detected, nil otherwise
    def check_recursive_redirect(task, redirect_url)
      visited_urls = task.redirects + [task.request.url]
      return nil unless visited_urls.include?(redirect_url)

      RecursiveRedirectError.new(
        url: redirect_url,
        http_method: task.request.http_method,
        duration: nil,
        request_id: task.id,
        redirects: visited_urls,
        callback_args: task.callback_args
      )
    end

    # Resolve a redirect URL, handling relative URLs.
    #
    # @param base_url [String] The base URL
    # @param location [String] The Location header value
    # @return [String] The resolved absolute URL
    def resolve_redirect_url(base_url, location)
      base_uri = URI.parse(base_url)
      redirect_uri = URI.parse(location)

      return location if redirect_uri.absolute?

      base_uri.merge(redirect_uri).to_s
    end
  end
end
