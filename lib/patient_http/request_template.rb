# frozen_string_literal: true

module PatientHttp
  # Builds requests that share settings, such as a base URL, headers, and a
  # timeout. Use a template to make many requests to the same API.
  #
  # The template joins each path with the base URL, and merges the headers and
  # query parameters of each request with its own.
  #
  # @example Build a request
  #   template = PatientHttp::RequestTemplate.new(
  #     base_url: "https://api.example.com",
  #     headers: {"Authorization" => "Bearer token"},
  #     timeout: 60
  #   )
  #   request = template.get("/users/123")
  #   PatientHttp.execute(request: request, callback: FetchUserCallback)
  class RequestTemplate
    # @return [String, URI::HTTP, nil] The base URL that relative paths are
    #   joined with.
    attr_accessor :base_url

    # @return [HttpHeaders] The default headers for all requests.
    attr_accessor :headers

    # @return [Numeric, nil] The default request timeout in seconds. If `nil`,
    #   the configured `request_timeout` applies.
    attr_accessor :timeout

    # Creates a template.
    #
    # @param base_url [String, URI::HTTP, nil] The base URL that relative paths
    #   are joined with.
    # @param headers [Hash] The default headers for all requests.
    # @param params [Hash, nil] The default query parameters for all requests.
    # @param timeout [Numeric, nil] The default request timeout in seconds. If
    #   `nil`, the configured `request_timeout` applies.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names
    #   of the default preprocessors for all requests.
    # @param processor [String, Symbol, nil] The name of the default processor for
    #   all requests.
    def initialize(base_url: nil, headers: {}, params: nil, timeout: nil, preprocessors: nil, processor: nil)
      @base_url = base_url
      @headers = HttpHeaders.new(headers)
      @params = params
      @timeout = timeout
      @preprocessors = preprocessors
      @processor = processor
    end

    # Builds a request.
    #
    # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`,
    #   `:patch`, `:delete`, or `:query`.
    # @param uri [String, URI::HTTP] The URL. A relative path is joined with the
    #   base URL.
    # @param body [String, nil] The request body.
    # @param json [Object, nil] An object to send as a JSON body. Can't be combined
    #   with `body`.
    # @param headers [Hash, nil] The headers to merge with the template headers.
    # @param params [Hash, nil] The query parameters to merge with the template
    #   parameters.
    # @param timeout [Numeric, nil] The request timeout in seconds. Overrides the
    #   template timeout.
    # @param max_redirects [Integer, nil] The maximum number of redirects to
    #   follow. If `0`, redirects aren't followed. If `nil`, the configuration
    #   value applies.
    # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a
    #   redirect that changes the HTTP method. If `nil`, the configuration value
    #   applies.
    # @param redirect_strip_headers [String, Array<String>, nil] The names of headers
    #   to remove from redirected requests, in addition to the configured names.
    #   Names are case insensitive.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
    #   the preprocessors for the request. Overrides the template preprocessors.
    # @param processor [String, Symbol, nil] The name of the processor for the
    #   request. Overrides the template processor.
    # @return [Request] The request.
    def request(
      method,
      uri,
      body: nil,
      json: nil,
      headers: nil,
      params: nil,
      timeout: nil,
      max_redirects: nil,
      follow_method_changing_redirects: nil,
      redirect_strip_headers: nil,
      preprocessors: nil,
      processor: nil
    )
      full_uri = @base_url ? URI.join(@base_url, uri.to_s) : URI(uri)

      merged_headers = headers&.any? ? @headers.merge(headers) : @headers
      merged_params = @params ? (@params.merge(params || {})) : params

      # Create request with all parameters
      Request.new(
        method,
        full_uri.to_s,
        headers: merged_headers.to_h,
        body: body,
        json: json,
        params: merged_params,
        timeout: timeout || @timeout,
        max_redirects: max_redirects,
        follow_method_changing_redirects: follow_method_changing_redirects,
        redirect_strip_headers: redirect_strip_headers,
        preprocessors: preprocessors || @preprocessors,
        processor: processor || @processor
      )
    end

    # Builds a GET request.
    #
    # @param uri [String, URI::HTTP] The URL. A relative path is joined with the
    #   base URL.
    # @param kwargs [Hash] The request options. See {#request}.
    # @return [Request] The request.
    def get(uri, **kwargs)
      request(:get, uri, **kwargs)
    end

    # Builds a HEAD request.
    #
    # @param uri [String, URI::HTTP] The URL. A relative path is joined with the
    #   base URL.
    # @param kwargs [Hash] The request options. See {#request}.
    # @return [Request] The request.
    def head(uri, **kwargs)
      request(:head, uri, **kwargs)
    end

    # Builds a POST request.
    #
    # @param uri [String, URI::HTTP] The URL. A relative path is joined with the
    #   base URL.
    # @param kwargs [Hash] The request options. See {#request}.
    # @return [Request] The request.
    def post(uri, **kwargs)
      request(:post, uri, **kwargs)
    end

    # Builds a PUT request.
    #
    # @param uri [String, URI::HTTP] The URL. A relative path is joined with the
    #   base URL.
    # @param kwargs [Hash] The request options. See {#request}.
    # @return [Request] The request.
    def put(uri, **kwargs)
      request(:put, uri, **kwargs)
    end

    # Builds a PATCH request.
    #
    # @param uri [String, URI::HTTP] The URL. A relative path is joined with the
    #   base URL.
    # @param kwargs [Hash] The request options. See {#request}.
    # @return [Request] The request.
    def patch(uri, **kwargs)
      request(:patch, uri, **kwargs)
    end

    # Builds a DELETE request.
    #
    # @param uri [String, URI::HTTP] The URL. A relative path is joined with the
    #   base URL.
    # @param kwargs [Hash] The request options. See {#request}.
    # @return [Request] The request.
    def delete(uri, **kwargs)
      request(:delete, uri, **kwargs)
    end

    # Builds a QUERY request.
    #
    # @param uri [String, URI::HTTP] The URL. A relative path is joined with the
    #   base URL.
    # @param kwargs [Hash] The request options. See {#request}.
    # @return [Request] The request.
    def query(uri, **kwargs)
      request(:query, uri, **kwargs)
    end
  end
end
