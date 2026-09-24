# frozen_string_literal: true

module PatientHttp
  # Builds HTTP requests with shared configuration.
  #
  # Use a request template when you make multiple requests to the same API with a
  # shared base URL, headers, and timeout.
  #
  # @example Basic usage
  #   template = PatientHttp::RequestTemplate.new(
  #     base_url: "https://api.example.com",
  #     headers: {"Authorization" => "Bearer token"},
  #     timeout: 60
  #   )
  #   request = template.get("/users/123")
  #
  # The template joins URLs, merges headers, and encodes query parameters.
  class RequestTemplate
    # @return [String, URI::HTTP, nil] The base URL for relative URIs.
    attr_accessor :base_url

    # @return [HttpHeaders] The default headers for all requests.
    attr_accessor :headers

    # @return [Float] The default request timeout, in seconds.
    attr_accessor :timeout

    # Creates a request template.
    #
    # @param base_url [String, URI::HTTP, nil] The base URL for relative URIs.
    # @param headers [Hash] The default headers for all requests.
    # @param params [Hash, nil] The default query parameters for all requests.
    # @param timeout [Float] The default request timeout, in seconds.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The default
    #   preprocessors to apply to all requests.
    # @param processor [String, Symbol, nil] The default processor name for all requests.
    def initialize(base_url: nil, headers: {}, params: nil, timeout: 30, preprocessors: nil, processor: nil)
      @base_url = base_url
      @headers = HttpHeaders.new(headers)
      @params = params
      @timeout = timeout
      @preprocessors = preprocessors
      @processor = processor
    end

    # Builds an HTTP request.
    #
    # @param method [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`, `:patch`,
    #   `:delete`, or `:query`.
    # @param uri [String, URI::HTTP] The URI or path to request. A relative path is joined
    #   with `base_url`.
    # @param body [String, nil] The request body.
    # @param json [Object, nil] An object to serialize as the JSON body. You can't use this
    #   parameter with `body`.
    # @param headers [Hash] Additional headers to merge with the template headers.
    # @param params [Hash, nil] The query parameters to add to the URL.
    # @param timeout [Numeric, nil] The request timeout, in seconds. Overrides the template
    #   default.
    # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a redirect that
    #   changes the HTTP method. `nil` uses the configuration default.
    # @param redirect_strip_headers [String, Array<String>, nil] Header names to strip from
    #   redirected requests, in addition to the configured names. Names are case insensitive.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The preprocessors to
    #   apply to the request. Overrides the template default.
    # @param processor [String, Symbol, nil] The processor name for the request. Overrides the
    #   template default.
    # @return [Request] The request.
    def request(
      method,
      uri,
      body: nil,
      json: nil,
      headers: nil,
      params: nil,
      timeout: nil,
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
        follow_method_changing_redirects: follow_method_changing_redirects,
        redirect_strip_headers: redirect_strip_headers,
        preprocessors: preprocessors || @preprocessors,
        processor: processor || @processor
      )
    end

    # Builds a GET request.
    #
    # @param uri [String, URI::HTTP] The URI or path to request.
    # @param kwargs [Hash] Additional options to pass to {#request}.
    # @return [Request] The request.
    def get(uri, **kwargs)
      request(:get, uri, **kwargs)
    end

    # Builds a HEAD request.
    #
    # @param uri [String, URI::HTTP] The URI or path to request.
    # @param kwargs [Hash] Additional options to pass to {#request}.
    # @return [Request] The request.
    def head(uri, **kwargs)
      request(:head, uri, **kwargs)
    end

    # Builds a POST request.
    #
    # @param uri [String, URI::HTTP] The URI or path to request.
    # @param kwargs [Hash] Additional options to pass to {#request}.
    # @return [Request] The request.
    def post(uri, **kwargs)
      request(:post, uri, **kwargs)
    end

    # Builds a PUT request.
    #
    # @param uri [String, URI::HTTP] The URI or path to request.
    # @param kwargs [Hash] Additional options to pass to {#request}.
    # @return [Request] The request.
    def put(uri, **kwargs)
      request(:put, uri, **kwargs)
    end

    # Builds a PATCH request.
    #
    # @param uri [String, URI::HTTP] The URI or path to request.
    # @param kwargs [Hash] Additional options to pass to {#request}.
    # @return [Request] The request.
    def patch(uri, **kwargs)
      request(:patch, uri, **kwargs)
    end

    # Builds a DELETE request.
    #
    # @param uri [String, URI::HTTP] The URI or path to request.
    # @param kwargs [Hash] Additional options to pass to {#request}.
    # @return [Request] The request.
    def delete(uri, **kwargs)
      request(:delete, uri, **kwargs)
    end

    # Builds a QUERY request.
    #
    # @param uri [String, URI::HTTP] The URI or path to request.
    # @param kwargs [Hash] Additional options to pass to {#request}.
    # @return [Request] The request.
    def query(uri, **kwargs)
      request(:query, uri, **kwargs)
    end
  end
end
