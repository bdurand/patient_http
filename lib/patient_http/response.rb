# frozen_string_literal: true

module PatientHttp
  # Represents the HTTP response of an async request.
  #
  # This class holds the response data, which includes the status, the headers, the
  # body, and information about the request that produced the response.
  class Response
    UNDEFINED = Object.new.freeze
    private_constant :UNDEFINED

    # @return [Integer] The HTTP status code.
    attr_reader :status

    # The response headers. A header that appeared more than once in the response,
    # such as set-cookie, is joined into a single string value.
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

    # @return [Array<String>] The URLs that were visited in the redirect chain. The
    #   array is empty if there were no redirects.
    attr_reader :redirects

    class << self
      # Reconstructs a Response from a hash.
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

    # Initializes a new Response.
    #
    # @param status [Integer] The HTTP status code.
    # @param headers [Hash, HttpHeaders] The response headers.
    # @param body [String, nil] The response body.
    # @param duration [Float] The request duration, in seconds.
    # @param request_id [String] The request ID.
    # @param url [String] The request URL.
    # @param http_method [Symbol] The HTTP method.
    # @param callback_args [Hash, nil] The callback arguments, with string keys.
    # @param redirects [Array<String>, nil] The URLs that were visited in the redirect
    #   chain.
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

    # Returns the callback arguments as a {CallbackArgs} object.
    #
    # @return [CallbackArgs] The callback arguments.
    def callback_args
      @callback_args ||= CallbackArgs.load(@callback_args_data)
    end

    # Returns the response body, and decodes it from the payload if necessary.
    #
    # @return [String, nil] The decoded response body, or nil if there is no body.
    def body
      @body = @payload&.value if @body.equal?(UNDEFINED)
      @body
    end

    # Checks whether the response is successful, that is, whether it has a 2xx status.
    #
    # @return [Boolean] Whether the response is successful.
    def success?
      status >= 200 && status < 300
    end

    # Checks whether the response is a redirect, that is, whether it has a 3xx status.
    #
    # @return [Boolean] Whether the response is a redirect.
    def redirect?
      status >= 300 && status < 400
    end

    # Checks whether the response is a client error, that is, whether it has a 4xx
    # status.
    #
    # @return [Boolean] Whether the response is a client error.
    def client_error?
      status >= 400 && status < 500
    end

    # Checks whether the response is a server error, that is, whether it has a 5xx
    # status.
    #
    # @return [Boolean] Whether the response is a server error.
    def server_error?
      status >= 500 && status < 600
    end

    # Checks whether the response is an error, that is, whether it has a 4xx or 5xx
    # status.
    #
    # @return [Boolean] Whether the response is an error.
    def error?
      status >= 400 && status < 600
    end

    # Returns the Content-Type header.
    #
    # @return [String, nil] The Content-Type header value.
    def content_type
      headers["content-type"]
    end

    # Checks whether the Content-Type header names a JSON type.
    #
    # @return [Boolean] Whether the body is JSON.
    def json?
      type = content_type.to_s.downcase
      type.match?(%r{\Aapplication/[^ ]*json\b}) || type == "text/json"
    end

    # Parses the response body as JSON.
    #
    # @return [Hash, Array] The parsed JSON.
    # @raise [RuntimeError] If the Content-Type header does not name a JSON type.
    # @raise [JSON::ParserError] If the body is not valid JSON.
    def json
      unless json?
        raise "Response Content-Type is not application/json (got: #{content_type.inspect})"
      end

      JSON.parse(body)
    end

    # Converts the response to a hash for JSON serialization.
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
    # @param options [Hash] The options to pass to `JSON.generate`. This parameter
    #   exists for compatibility with ActiveSupport.
    # @return [String] The JSON representation.
    def to_json(options = nil)
      JSON.generate(as_json, options)
    end
  end
end
