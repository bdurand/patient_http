# frozen_string_literal: true

module PatientHttp
  # The RequestTemplate is used to build HTTP requests with shared configuration.
  #
  # Use RequestTemplate when you need to make multiple requests to the same API with shared
  # configuration (base URL, headers, timeout).
  #
  # @example Basic usage
  #   template = PatientHttp::RequestTemplate.new(
  #     base_url: "https://api.example.com",
  #     headers: {"Authorization" => "Bearer token"},
  #     timeout: 60
  #   )
  #   request = template.get("/users/123")
  #
  # The RequestTemplate handles building HTTP requests with proper URL joining, header merging,
  # and parameter encoding.
  class RequestTemplate
    # @return [String, URI::HTTP, nil] Base URL for relative URIs
    attr_accessor :base_url

    # @return [HttpHeaders] Default headers for all requests
    attr_accessor :headers

    # @return [Float] Default request timeout in seconds
    attr_accessor :timeout

    # Initializes a new RequestTemplate.
    #
    # @param base_url [String, URI::HTTP, nil] Base URL for relative URIs
    # @param headers [Hash] Default headers for all requests
    # @param params [Hash, nil] Default query parameters to add to all requests
    # @param timeout [Float] Default request timeout in seconds
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] Default preprocessors
    #   to apply to all requests
    def initialize(base_url: nil, headers: {}, params: nil, timeout: 30, preprocessors: nil)
      @base_url = base_url
      @headers = HttpHeaders.new(headers)
      @params = params
      @timeout = timeout
      @preprocessors = preprocessors
    end

    # Build an async HTTP request. Returns a Request object.
    #
    # @param method [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
    # @param uri [String, URI::HTTP] URI path to request (joined with base_url if relative)
    # @param body [String, nil] request body
    # @param json [Object, nil] JSON object to serialize (cannot use with body)
    # @param headers [Hash] additional headers to merge with client headers
    # @param params [Hash, nil] query parameters to add to URL
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] preprocessors to apply
    #   to the request (overrides the template default)
    # @return [Request] request object
    def request(method, uri, body: nil, json: nil, headers: nil, params: nil, timeout: nil, preprocessors: nil)
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
        preprocessors: preprocessors || @preprocessors
      )
    end

    # Convenience method for GET requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #request)
    # @return [Request] request object
    def get(uri, **kwargs)
      request(:get, uri, **kwargs)
    end

    # Convenience method for POST requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #request)
    # @return [Request] request object
    def post(uri, **kwargs)
      request(:post, uri, **kwargs)
    end

    # Convenience method for PUT requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #request)
    # @return [Request] request object
    def put(uri, **kwargs)
      request(:put, uri, **kwargs)
    end

    # Convenience method for PATCH requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #request)
    # @return [Request] request object
    def patch(uri, **kwargs)
      request(:patch, uri, **kwargs)
    end

    # Convenience method for DELETE requests.
    #
    # @param uri [String, URI::HTTP] URI path to request
    # @param kwargs [Hash] additional options (see #request)
    # @return [Request] request object
    def delete(uri, **kwargs)
      request(:delete, uri, **kwargs)
    end
  end
end
