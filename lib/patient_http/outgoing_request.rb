# frozen_string_literal: true

module PatientHttp
  # A changeable view of a request as it is about to be sent, after the secret
  # references are resolved and after the send-time headers, x-request-id and the
  # default user-agent, are set.
  #
  # A preprocessor that is attached to a request receives this object and can change
  # the headers or append query parameters before the request goes out, for example to
  # sign the request. The HTTP method, URL, and body are read-only. You can change the
  # headers in place, and you can append query parameters with {#add_param}.
  #
  # @see Configuration#register_preprocessor
  class OutgoingRequest
    # @return [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`, `:patch`,
    #   `:delete`, or `:query`.
    attr_reader :http_method

    # @return [String] The request URL, with any secret query parameters already
    #   resolved.
    attr_reader :url

    # @return [String, nil] The request body.
    attr_reader :body

    # @return [HttpHeaders] The case insensitive request headers, which you can
    #   change.
    attr_reader :headers

    # Initializes a new OutgoingRequest.
    #
    # @param http_method [Symbol] The HTTP method.
    # @param url [String] The resolved request URL.
    # @param headers [HttpHeaders] The resolved request headers.
    # @param body [String, nil] The request body.
    def initialize(http_method:, url:, headers:, body:)
      @http_method = http_method
      @url = url.to_s
      @headers = headers
      @body = body
    end

    # Appends a query parameter to the request URL.
    #
    # @param name [String, Symbol] The parameter name.
    # @param value [Object] The parameter value.
    # @return [String] The updated URL.
    def add_param(name, value)
      serialized_param = URI.encode_www_form([[name.to_s, value]])
      uri = URI(@url)
      uri.query = [uri.query, serialized_param].compact.reject(&:empty?).join("&")
      @url = uri.to_s
    end

    # Returns a description of the outgoing request. The header values, the query
    # string, and the body are not shown, because they can contain resolved secrets.
    #
    # @return [String] The description of the request.
    def inspect
      "#<#{self.class.name} #{http_method.to_s.upcase} #{redacted_url} headers=#{headers.to_h.keys.inspect}>"
    end

    private

    def redacted_url
      uri = URI(@url)
      uri.query = nil
      uri.user = nil
      uri.password = nil
      uri.to_s
    rescue URI::InvalidURIError
      "<invalid url>"
    end
  end
end
