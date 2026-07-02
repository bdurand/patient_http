# frozen_string_literal: true

module PatientHttp
  # A mutable view of a request as it is about to be sent, after secret references
  # have been resolved and the send-time headers (x-request-id and the default
  # user-agent) have been set.
  #
  # Preprocessors attached to a request receive this object and can modify the
  # headers or append query parameters before the request goes out -- for example,
  # to sign the request. The HTTP method, URL, and body are read-only; headers can
  # be changed in place and query parameters appended with {#add_param}.
  #
  # @see Configuration#register_preprocessor
  class OutgoingRequest
    # @return [Symbol] HTTP method (:get, :post, :put, :patch, :delete)
    attr_reader :http_method

    # @return [String] the request URL with any secret query params already resolved
    attr_reader :url

    # @return [String, nil] the request body
    attr_reader :body

    # @return [HttpHeaders] mutable, case-insensitive request headers
    attr_reader :headers

    # Initialize a new OutgoingRequest.
    #
    # @param http_method [Symbol] the HTTP method
    # @param url [String] the resolved request URL
    # @param headers [HttpHeaders] the resolved request headers
    # @param body [String, nil] the request body
    def initialize(http_method:, url:, headers:, body:)
      @http_method = http_method
      @url = url.to_s
      @headers = headers
      @body = body
    end

    # Append a query parameter to the request URL.
    #
    # @param name [String, Symbol] the parameter name
    # @param value [Object] the parameter value
    # @return [String] the updated URL
    def add_param(name, value)
      serialized_param = URI.encode_www_form([[name.to_s, value]])
      uri = URI(@url)
      uri.query = [uri.query, serialized_param].compact.reject(&:empty?).join("&")
      @url = uri.to_s
    end

    # Inspect the outgoing request. Header values, the query string, and the body
    # are not shown since they may contain resolved secrets.
    #
    # @return [String]
    def inspect
      "#<#{self.class.name} #{http_method.to_s.upcase} #{redacted_url} headers=#{headers.to_h.keys.inspect}>"
    end

    private

    def redacted_url
      uri = URI(@url)
      uri.query = nil
      uri.to_s
    rescue URI::InvalidURIError
      "<invalid url>"
    end
  end
end
