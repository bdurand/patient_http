# frozen_string_literal: true

module PatientHttp
  # A mutable view of a request right before it's sent. At this point, secret
  # references are resolved and the send-time headers, `x-request-id` and the
  # default `user-agent`, are set.
  #
  # Preprocessors attached to a request receive this object. They can change the
  # headers or append query parameters before the request is sent, for example to
  # sign the request. The HTTP method, URL, and body are read-only. You can change
  # headers in place and append query parameters with {#add_param}.
  #
  # @see Configuration#register_preprocessor
  class OutgoingRequest
    # @return [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`, `:patch`,
    #   `:delete`, or `:query`.
    attr_reader :http_method

    # @return [String] The request URL with any secret query parameters resolved.
    attr_reader :url

    # @return [String, nil] The request body.
    attr_reader :body

    # @return [HttpHeaders] The mutable, case-insensitive request headers.
    attr_reader :headers

    # Creates an outgoing request.
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

    # Returns a string representation of the outgoing request. Header values, the
    # query string, and the body aren't shown, because they might contain resolved
    # secrets.
    #
    # @return [String]
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
