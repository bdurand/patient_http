# frozen_string_literal: true

module PatientHttp
  # Represents an HTTP request that the async processor runs.
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

    # The valid HTTP methods.
    VALID_METHODS = %i[get head post put patch delete query].freeze

    # The HTTP methods that must not carry a request body.
    BODYLESS_METHODS = %i[get head delete].freeze

    # @return [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`, `:patch`,
    #   `:delete`, or `:query`.
    attr_reader :http_method

    # @return [String] The request URL.
    attr_reader :url

    # @return [HttpHeaders] The request headers.
    attr_reader :headers

    # @return [Numeric, nil] The overall timeout, in seconds.
    attr_reader :timeout

    # @return [Integer, nil] The maximum number of redirects to follow. A value of nil
    #   uses the configured default, and 0 disables redirects.
    attr_reader :max_redirects

    # @return [Boolean, nil] Whether to follow a redirect that requires a change of
    #   the HTTP method, such as POST to GET on a 302. A value of nil uses the
    #   configured default.
    attr_reader :follow_method_changing_redirects

    # @return [Array<String>] The lowercase header names that are stripped from
    #   redirected requests, in addition to the names on the {Configuration}.
    attr_reader :redirect_strip_headers

    # @return [Hash{String, Symbol => SecretReference}] The query parameters whose
    #   values are secret references. These are kept out of the serialized URL and
    #   resolved at send time.
    attr_reader :secret_params

    # @return [Array<String>] The names of the preprocessors that are registered on
    #   the configuration and that apply to the request when it is sent.
    attr_reader :preprocessors

    # @return [String, nil] The name of the processor that runs the request.
    #   Integrations use this name to route the request to a named processor. A value
    #   of nil uses the default processor.
    attr_reader :processor

    class << self
      # Reconstructs a Request from a hash.
      #
      # @param hash [Hash] The hash representation.
      # @return [Request] The reconstructed request.
      def load(hash)
        new(
          hash["http_method"].to_sym,
          hash["url"],
          headers: load_headers(hash["headers"]),
          body: Payload.load(hash["body"])&.value,
          params: load_secret_params(hash["secret_params"]),
          timeout: hash["timeout"],
          max_redirects: hash["max_redirects"],
          follow_method_changing_redirects: hash["follow_method_changing_redirects"],
          redirect_strip_headers: hash["redirect_strip_headers"],
          preprocessors: hash["preprocessors"],
          processor: hash["processor"]
        )
      end

      private

      # Converts the serialized secret reference markers in the headers back into
      # {SecretReference} objects, and leaves the plain header values unchanged.
      def load_headers(headers)
        return headers if headers.nil?

        headers.transform_values { |value| SecretReference.load(value) }
      end

      # Reconstructs the secret parameters from their serialized markers. The result
      # is a parameter hash, so that the constructor folds the parameters back into
      # the secret parameters of the request.
      def load_secret_params(secret_params)
        return nil if secret_params.nil? || secret_params.empty?

        secret_params.transform_values { |value| SecretReference.load(value) }
      end
    end

    # Initializes a new Request.
    #
    # @param http_method [Symbol, String] The HTTP method: `:get`, `:head`, `:post`,
    #   `:put`, `:patch`, `:delete`, or `:query`.
    # @param url [String, URI::Generic] The request URL.
    # @param headers [Hash, HttpHeaders] The request headers.
    # @param body [String, nil] The request body.
    # @param json [Object, nil] A JSON body to serialize. Use this instead of the
    #   body parameter.
    # @param params [Hash, nil] The query parameters to append to the URL.
    # @param timeout [Numeric, nil] The overall timeout, in seconds.
    # @param max_redirects [Integer, nil] The maximum number of redirects to follow.
    #   Use nil for the configured default, or 0 to disable redirects.
    # @param follow_method_changing_redirects [Boolean, nil] Whether to follow a
    #   redirect that requires a change of the HTTP method. Use nil for the configured
    #   default. When false, the redirect response is returned as the result instead.
    # @param redirect_strip_headers [String, Array<String>, nil] Header names (case
    #   insensitive) to strip from redirected requests, in addition to the names on
    #   the {Configuration}.
    # @param preprocessors [String, Symbol, Array<String, Symbol>, nil] The names of
    #   the preprocessors that are registered on the configuration and that apply to
    #   the request when it is sent.
    # @param processor [String, Symbol, nil] The name of the processor that runs the
    #   request. Integrations use this name to route the request to a named processor.
    def initialize(
      http_method,
      url,
      headers: {},
      body: nil,
      json: nil,
      params: nil,
      timeout: nil,
      max_redirects: nil,
      follow_method_changing_redirects: nil,
      redirect_strip_headers: nil,
      preprocessors: nil,
      processor: nil
    )
      @http_method = http_method.is_a?(String) ? http_method.downcase.to_sym : http_method

      unless url.nil? || url.is_a?(String) || url.is_a?(URI::Generic)
        raise ArgumentError.new("url must be a String or URI, got: #{url.class}")
      end

      @secret_params = {}
      @url = normalized_url(url, params)
      # Copy the headers so the request does not share mutable state with the
      # caller (or with another request when following redirects).
      @headers = headers.is_a?(HttpHeaders) ? headers.dup : HttpHeaders.new(headers)
      @body = (body == "") ? nil : body
      @timeout = timeout
      @max_redirects = max_redirects
      @follow_method_changing_redirects = normalized_follow_method_changing_redirects(follow_method_changing_redirects)
      @redirect_strip_headers = RedirectHelper.normalize_header_names(redirect_strip_headers)
      @preprocessors = normalized_preprocessors(preprocessors)
      @processor = normalized_processor(processor)

      if json
        raise ArgumentError.new("Cannot provide both body and json") if @body

        @body = JSON.generate(json)
        @headers["content-type"] ||= "application/json; charset=utf-8"
      end

      validate!

      encoding, encoded_body, charset = Payload.encode(@body, @headers["content-type"])
      @payload = Payload.new(encoding, encoded_body, charset) unless @body.nil?
      @body = UNDEFINED
    end

    # Returns the request body, and decodes it from the payload if necessary.
    #
    # @return [String, nil] The decoded request body, or nil if there is no body.
    def body
      @body = @payload&.value if @body.equal?(UNDEFINED)
      @body
    end

    # Converts the request to a hash for JSON serialization.
    #
    # @return [Hash] The hash representation.
    def as_json
      hash = {
        "http_method" => @http_method.to_s,
        "url" => @url.to_s,
        "headers" => serialized_headers,
        "body" => @payload&.as_json,
        "timeout" => @timeout,
        "max_redirects" => @max_redirects
      }

      if @secret_params.any?
        hash["secret_params"] = @secret_params.transform_values(&:as_json)
      end

      unless @follow_method_changing_redirects.nil?
        hash["follow_method_changing_redirects"] = @follow_method_changing_redirects
      end

      hash["redirect_strip_headers"] = @redirect_strip_headers if @redirect_strip_headers.any?

      hash["preprocessors"] = @preprocessors if @preprocessors.any?
      hash["processor"] = @processor if @processor

      hash
    end

    private

    # A header value can be a {SecretReference} object, which is serialized as a
    # marker.
    def serialized_headers
      @headers.to_h.transform_values do |value|
        value.is_a?(SecretReference) ? value.as_json : value
      end
    end

    # Normalizes the method-changing redirect flag to true, false, or nil.
    def normalized_follow_method_changing_redirects(value)
      return nil if value.nil?
      return value if value == true || value == false

      raise ArgumentError.new("follow_method_changing_redirects must be true, false, or nil, got: #{value.inspect}")
    end

    # Normalizes the processor name to a frozen string or to nil.
    def normalized_processor(processor)
      return nil if processor.nil?

      name = processor.to_s
      raise ArgumentError.new("processor name cannot be empty") if name.empty?

      name.freeze
    end

    # Normalizes the preprocessor names to a frozen array of strings.
    def normalized_preprocessors(preprocessors)
      names = Array(preprocessors).map(&:to_s)
      if names.any?(&:empty?)
        raise ArgumentError.new("preprocessor names cannot be empty")
      end

      names.freeze
    end

    def normalized_url(url, params)
      uri = url.is_a?(URI::Generic) ? url.dup : URI(url.to_s)
      return uri.to_s unless params&.any?

      # Separate the secret parameters. They are kept off the serialized URL, and the
      # processor resolves them at send time. Only the parameters that are not secret
      # are folded into the URL.
      regular_params = {}
      params.each do |key, value|
        if SecretReference.reference?(value)
          @secret_params[key] = SecretReference.load(value)
        else
          regular_params[key] = value
        end
      end

      return uri.to_s if regular_params.empty?

      serialized_params = URI.encode_www_form(regular_params)
      uri.query = [uri.query, serialized_params].compact.reject(&:empty?).join("&")
      uri.to_s
    end

    # Validates that the request has the required HTTP parameters.
    #
    # @return [self] The request, so that you can chain calls.
    # @raise [ArgumentError] If the method or the URL is not valid.
    def validate!
      unless VALID_METHODS.include?(@http_method)
        raise ArgumentError.new("method must be one of #{VALID_METHODS.inspect}, got: #{@http_method.inspect}")
      end

      raise ArgumentError.new("url is required") if @url.nil? || (@url.is_a?(String) && @url.empty?)

      unless @url.is_a?(String) || @url.is_a?(URI::Generic)
        raise ArgumentError.new("url must be a String or URI, got: #{@url.class}")
      end

      if BODYLESS_METHODS.include?(@http_method) && !@body.nil?
        raise ArgumentError.new("body is not allowed for #{@http_method.upcase} requests")
      end

      if @body && !@body.is_a?(String)
        raise ArgumentError.new("body must be a String, got: #{@body.class}")
      end

      self
    end
  end
end
