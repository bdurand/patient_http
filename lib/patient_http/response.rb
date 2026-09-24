# frozen_string_literal: true

module PatientHttp
  # The HTTP response to an async request.
  #
  # A response holds the status, headers, and body, and details about the
  # request that returned it. Responses can be serialized to JSON, so they can
  # go through a job queue.
  class Response
    UNDEFINED = Object.new.freeze
    private_constant :UNDEFINED

    # @return [Integer] The HTTP status code.
    attr_reader :status

    # The response headers. A header that occurs more than one time in the
    # response, such as `set-cookie`, becomes one string with the values joined.
    #
    # @return [HttpHeaders] The response headers.
    attr_reader :headers

    # @return [Float] The request duration in seconds.
    attr_reader :duration

    # @return [String] The request ID.
    attr_reader :request_id

    # @return [String] The request URL.
    attr_reader :url

    # @return [Symbol] The HTTP method.
    attr_reader :http_method

    # @return [Array<String>] The URLs of the redirects that were followed, in
    #   order. Empty if no redirects were followed.
    attr_reader :redirects

    class << self
      # Creates a response from its serialized form.
      #
      # @param hash [Hash] The hash from {#as_json}.
      # @return [Response] The response.
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
    # @param duration [Float] The request duration in seconds.
    # @param request_id [String] The request ID.
    # @param url [String] The request URL.
    # @param http_method [Symbol] The HTTP method.
    # @param callback_args [Hash, nil] The callback arguments, with string keys.
    # @param redirects [Array<String>, nil] The URLs of the redirects that were
    #   followed.
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

    # Returns the callback arguments that were passed with the request.
    #
    # @return [CallbackArgs] The callback arguments.
    def callback_args
      @callback_args ||= CallbackArgs.load(@callback_args_data)
    end

    # Returns the response body. The body is decoded on first access.
    #
    # @return [String, nil] The response body, or `nil` if the response has no
    #   body.
    def body
      @body = @payload&.value if @body.equal?(UNDEFINED)
      @body
    end

    # Returns whether the status is 2xx.
    #
    # @return [Boolean] `true` if the request succeeded.
    def success?
      status >= 200 && status < 300
    end

    # Returns whether the status is 3xx.
    #
    # @return [Boolean] `true` if the response is a redirect.
    def redirect?
      status >= 300 && status < 400
    end

    # Returns whether the status is 4xx.
    #
    # @return [Boolean] `true` if the response is a client error.
    def client_error?
      status >= 400 && status < 500
    end

    # Returns whether the status is 5xx.
    #
    # @return [Boolean] `true` if the response is a server error.
    def server_error?
      status >= 500 && status < 600
    end

    # Returns whether the status is 4xx or 5xx.
    #
    # @return [Boolean] `true` if the response is an error.
    def error?
      status >= 400 && status < 600
    end

    # Returns the value of the `content-type` header.
    #
    # @return [String, nil] The content type, or `nil` if the header isn't set.
    def content_type
      headers["content-type"]
    end

    # Returns whether the `content-type` header identifies a JSON body.
    #
    # @return [Boolean] `true` if the body is JSON.
    def json?
      type = content_type.to_s.downcase
      type.match?(%r{\Aapplication/[^ ]*json\b}) || type == "text/json"
    end

    # Parses the response body as JSON.
    #
    # @return [Hash, Array] The parsed body.
    # @raise [RuntimeError] If the `content-type` header doesn't identify a JSON
    #   body.
    # @raise [JSON::ParserError] If the body isn't valid JSON.
    def json
      unless json?
        raise "Response Content-Type is not application/json (got: #{content_type.inspect})"
      end

      JSON.parse(body)
    end

    # Returns the response as a JSON-compatible hash.
    #
    # @return [Hash] The serialized response.
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

    # Returns the response as a JSON string.
    #
    # @param options [Hash, nil] The options for `JSON.generate`. This parameter
    #   makes the method compatible with Active Support.
    # @return [String] The JSON string.
    def to_json(options = nil)
      JSON.generate(as_json, options)
    end
  end
end
