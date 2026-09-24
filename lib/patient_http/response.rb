# frozen_string_literal: true

module PatientHttp
  # An HTTP response to an asynchronous request.
  #
  # A response holds the status, headers, and body, and metadata about the
  # request that produced it.
  class Response
    UNDEFINED = Object.new.freeze
    private_constant :UNDEFINED

    # @return [Integer] The HTTP status code.
    attr_reader :status

    # The response headers. A header that appears more than once in the response,
    # such as `set-cookie`, is joined into a single string value.
    #
    # @return [HttpHeaders] The response headers.
    attr_reader :headers

    # @return [Float] The request duration, in seconds.
    attr_reader :duration

    # @return [String] The request ID.
    attr_reader :request_id

    # @return [String] The request URL.
    attr_reader :url

    # @return [Symbol] The HTTP method.
    attr_reader :http_method

    # @return [Array<String>] The URLs visited in the redirect chain. Empty if there were
    #   no redirects.
    attr_reader :redirects

    class << self
      # Reconstructs a response from a hash.
      #
      # @param hash [Hash] The hash representation.
      # @return [Response] The reconstructed response.
      def load(hash)
        new(
          status: hash["status"],
          headers: hash["headers"],
          body: Payload.load(hash["body"])&.value,
          duration: hash["duration"],
          request_id: hash["request_id"],
          url: hash["url"],
          http_method: hash["http_method"]&.to_sym,
          callback_args: hash["callback_args"],
          redirects: hash["redirects"]
        )
      end
    end

    # Creates a response.
    #
    # @param status [Integer] The HTTP status code.
    # @param headers [Hash, HttpHeaders] The response headers.
    # @param body [String, nil] The response body.
    # @param duration [Float] The request duration, in seconds.
    # @param request_id [String] The request ID.
    # @param url [String] The request URL.
    # @param http_method [Symbol] The HTTP method.
    # @param callback_args [Hash, nil] The callback arguments, with string keys.
    # @param redirects [Array<String>, nil] The URLs visited in the redirect chain.
    def initialize(status:, headers:, body:, duration:, request_id:, url:, http_method:, callback_args: nil, redirects: nil)
      @status = status
      @headers = HttpHeaders.new(headers)

      encoding, encoded_body, charset = Payload.encode(body, @headers["content-type"])
      @payload = Payload.new(encoding, encoded_body, charset) unless body.nil?
      @body = UNDEFINED

      @duration = duration
      @request_id = request_id
      @url = url
      @http_method = http_method
      @callback_args_data = callback_args || {}
      @redirects = redirects || []
    end

    # Returns the callback arguments.
    #
    # @return [CallbackArgs] The callback arguments.
    def callback_args
      @callback_args ||= CallbackArgs.load(@callback_args_data)
    end

    # Returns the response body, decoded from the payload if needed.
    #
    # @return [String, nil] The decoded response body, or `nil` if there is no body.
    def body
      @body = @payload&.value if @body.equal?(UNDEFINED)
      @body
    end

    # Returns `true` if the response is successful (2xx status).
    #
    # @return [Boolean]
    def success?
      status >= 200 && status < 300
    end

    # Returns `true` if the response is a redirect (3xx status).
    #
    # @return [Boolean]
    def redirect?
      status >= 300 && status < 400
    end

    # Returns `true` if the response is a client error (4xx status).
    #
    # @return [Boolean]
    def client_error?
      status >= 400 && status < 500
    end

    # Returns `true` if the response is a server error (5xx status).
    #
    # @return [Boolean]
    def server_error?
      status >= 500 && status < 600
    end

    # Returns `true` if the response is an error (4xx or 5xx status).
    #
    # @return [Boolean]
    def error?
      status >= 400 && status < 600
    end

    # Returns the `Content-Type` header.
    #
    # @return [String, nil]
    def content_type
      headers["content-type"]
    end

    # Returns `true` if the `Content-Type` header indicates JSON.
    #
    # @return [Boolean]
    def json?
      type = content_type.to_s.downcase
      type.match?(%r{\Aapplication/[^ ]*json\b}) || type == "text/json"
    end

    # Parses the response body as JSON.
    #
    # @return [Hash, Array] The parsed JSON.
    # @raise [RuntimeError] If the `Content-Type` isn't `application/json`.
    # @raise [JSON::ParserError] If the body isn't valid JSON.
    def json
      unless json?
        raise "Response Content-Type is not application/json (got: #{content_type.inspect})"
      end

      JSON.parse(body)
    end

    # Serializes the response to a hash for JSON encoding.
    #
    # @return [Hash] The hash representation.
    def as_json
      {
        "status" => status,
        "headers" => headers.to_h,
        "body" => @payload&.as_json,
        "duration" => duration,
        "request_id" => request_id,
        "url" => url,
        "http_method" => http_method.to_s,
        "callback_args" => @callback_args_data,
        "redirects" => @redirects
      }
    end

    # Serializes the response to a JSON string.
    #
    # @param options [Hash] Options to pass to `JSON.generate`. This parameter provides
    #   compatibility with ActiveSupport.
    # @return [String] The JSON representation.
    def to_json(options = nil)
      JSON.generate(as_json, options)
    end
  end
end
