# frozen_string_literal: true

module PatientHttp
  # A request immediately before it's sent. Secret references are resolved, and
  # the `x-request-id` and default `user-agent` headers are set.
  #
  # Preprocessors receive this object. They can change the headers and add
  # query parameters, for example to sign the request. The HTTP method, URL,
  # and body are read-only. Change the headers in place, and add query
  # parameters with {#add_param}.
  #
  # @see Configuration#register_preprocessor
  class OutgoingRequest
    # @return [Symbol] The HTTP method: `:get`, `:head`, `:post`, `:put`,
    #   `:patch`, `:delete`, or `:query`.
    attr_reader :http_method

    # @return [String] The request URL, with the secret query parameters
    #   resolved.
    attr_reader :url

    # @return [String, nil] The request body.
    attr_reader :body

    # @return [HttpHeaders] The request headers. You can change them. Names are
    #   case insensitive.
    attr_reader :headers

    # Creates an outgoing request.
    #
    # @param http_method [Symbol] The HTTP method.
    # @param url [String] The request URL, with secrets resolved.
    # @param headers [HttpHeaders] The request headers, with secrets resolved.
    # @param body [String, nil] The request body.
    def initialize(http_method:, url:, headers:, body:)
      @http_method = http_method
      @url = url.to_s
      @headers = headers
      @body = body
    end

    # Adds a query parameter to the request URL.
    #
    # @param name [String, Symbol] The parameter name.
    # @param value [Object] The parameter value.
    # @return [String] The new URL.
    def add_param(name, value)
      serialized_param = URI.encode_www_form([[name.to_s, value]])
      uri = URI(@url)
      uri.query = [uri.query, serialized_param].compact.reject(&:empty?).join("&")
      @url = uri.to_s
    end

    # Returns a description of the request. It doesn't show the header values,
    # the query string, or the body, because they can contain secrets.
    #
    # @return [String] The description.
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
