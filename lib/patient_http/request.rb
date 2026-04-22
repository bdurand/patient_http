# frozen_string_literal: true

module PatientHttp
  # Represents an async HTTP request that will be processed by the async processor.
  #
  # @example Creating a request
  #   request = PatientHttp::Request.new(:get, "https://api.example.com/users/123")
  #
  # @example Creating a POST request with JSON body
  #   request = PatientHttp::Request.new(
  #     :post,
  #     "https://api.example.com/users",
  #     json: {name: "John", email: "john@example.com"}
  #   )
  class Request
    UNDEFINED = Object.new.freeze
    private_constant :UNDEFINED

    # Valid HTTP methods
    VALID_METHODS = %i[get post put patch delete].freeze

    # @return [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
    attr_reader :http_method

    # @return [String] The request URL
    attr_reader :url

    # @return [HttpHeaders] Request headers
    attr_reader :headers

    # @return [Numeric, nil] Overall timeout in seconds
    attr_reader :timeout

    # @return [Integer, nil] Maximum number of redirects to follow (nil uses config default, 0 disables)
    attr_reader :max_redirects

    class << self
      # Reconstruct a Request from a hash
      #
      # @param hash [Hash] hash representation
      # @return [Request] reconstructed request
      def load(hash)
        new(
          hash["http_method"].to_sym,
          hash["url"],
          headers: hash["headers"],
          body: Payload.load(hash["body"])&.value,
          timeout: hash["timeout"],
          max_redirects: hash["max_redirects"]
        )
      end
    end

    # Initializes a new Request.
    #
    # @param http_method [Symbol, String] HTTP method (:get, :post, :put, :patch, :delete).
    # @param url [String, URI::Generic] The request URL.
    # @param headers [Hash, HttpHeaders] Request headers.
    # @param body [String, nil] Request body.
    # @param json [Object, nil] JSON body to be serialized (alternative to body).
    # @param params [Hash, nil] Query parameters to append to the URL.
    # @param timeout [Numeric, nil] Overall timeout in seconds.
    # @param max_redirects [Integer, nil] Maximum redirects to follow (nil uses config, 0 disables).
    def initialize(
      http_method,
      url,
      headers: {},
      body: nil,
      json: nil,
      params: nil,
      timeout: nil,
      max_redirects: nil
    )
      @http_method = http_method.is_a?(String) ? http_method.downcase.to_sym : http_method

      unless url.nil? || url.is_a?(String) || url.is_a?(URI::Generic)
        raise ArgumentError.new("url must be a String or URI, got: #{url.class}")
      end

      @url = normalized_url(url, params)
      @headers = headers.is_a?(HttpHeaders) ? headers : HttpHeaders.new(headers)
      @body = (body == "") ? nil : body
      @timeout = timeout
      @max_redirects = max_redirects

      if json
        raise ArgumentError.new("Cannot provide both body and json") if @body

        @body = JSON.generate(json)
        @headers["content-type"] ||= "application/json; encoding=utf-8"
      end

      validate!

      encoding, encoded_body, charset = Payload.encode(@body, @headers["content-type"])
      @payload = Payload.new(encoding, encoded_body, charset) unless @body.nil?
      @body = UNDEFINED
    end

    # Returns the request body, decoding it from the payload if necessary.
    #
    # @return [String, nil] The decoded request body or nil if there was no body.
    def body
      @body = @payload&.value if @body.equal?(UNDEFINED)
      @body
    end

    # Serialize to JSON hash.
    #
    # @return [Hash]
    def as_json
      {
        "http_method" => @http_method.to_s,
        "url" => @url.to_s,
        "headers" => @headers.to_h,
        "body" => @payload&.as_json,
        "timeout" => @timeout,
        "max_redirects" => @max_redirects
      }
    end

    private

    def normalized_url(url, params)
      uri = url.is_a?(URI::Generic) ? url.dup : URI(url.to_s)
      return uri.to_s unless params&.any?

      serialized_params = URI.encode_www_form(params)
      uri.query = [uri.query, serialized_params].compact.reject(&:empty?).join("&")
      uri.to_s
    end

    # Validate the request has required HTTP parameters.
    # @raise [ArgumentError] if method or url is invalid
    # @return [self] for chaining
    def validate!
      unless VALID_METHODS.include?(@http_method)
        raise ArgumentError.new("method must be one of #{VALID_METHODS.inspect}, got: #{@http_method.inspect}")
      end

      raise ArgumentError.new("url is required") if @url.nil? || (@url.is_a?(String) && @url.empty?)

      unless @url.is_a?(String) || @url.is_a?(URI::Generic)
        raise ArgumentError.new("url must be a String or URI, got: #{@url.class}")
      end

      if %i[get delete].include?(@http_method) && !@body.nil?
        raise ArgumentError.new("body is not allowed for #{@http_method.upcase} requests")
      end

      if @body && !@body.is_a?(String)
        raise ArgumentError.new("body must be a String, got: #{@body.class}")
      end

      self
    end
  end
end
