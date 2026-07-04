# frozen_string_literal: true

module PatientHttp
  # Represents an HTTP response from an async request.
  #
  # This class encapsulates the response data including status, headers, body,
  # and metadata about the request that generated it.
  class Response
    UNDEFINED = Object.new.freeze
    private_constant :UNDEFINED

    # @return [Integer] HTTP status code
    attr_reader :status

    # Response headers. Headers that appeared multiple times in the response
    # (such as set-cookie) are flattened into a single joined string value.
    #
    # @return [HttpHeaders] response headers
    attr_reader :headers

    # @return [Float] request duration in seconds
    attr_reader :duration

    # @return [String] request ID
    attr_reader :request_id

    # @return [String] request URL
    attr_reader :url

    # @return [Symbol] HTTP method
    attr_reader :http_method

    # @return [Array<String>] URLs visited during redirect chain (empty if no redirects)
    attr_reader :redirects

    class << self
      # Reconstruct a Response from a hash
      #
      # @param hash [Hash] hash representation
      # @return [Response] reconstructed response
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

    # Initialize a Response from an Async::HTTP::Response
    #
    # @param status [Integer] HTTP status code
    # @param headers [Hash, HttpHeaders] response headers
    # @param body [String, nil] response body
    # @param duration [Float] request duration in seconds
    # @param request_id [String] the request ID
    # @param url [String] the request URL
    # @param http_method [Symbol] the HTTP method
    # @param callback_args [Hash, nil] callback arguments (string keys)
    # @param redirects [Array<String>, nil] URLs visited during redirect chain
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

    # Returns the callback arguments as a CallbackArgs object.
    #
    # @return [CallbackArgs] the callback arguments
    def callback_args
      @callback_args ||= CallbackArgs.load(@callback_args_data)
    end

    # Returns the response body, decoding it from the payload if necessary.
    #
    # @return [String, nil] The decoded response body or nil if there was no body.
    def body
      @body = @payload&.value if @body.equal?(UNDEFINED)
      @body
    end

    # Check if response is successful (2xx status)
    #
    # @return [Boolean]
    def success?
      status >= 200 && status < 300
    end

    # Check if response is a redirect (3xx status)
    #
    # @return [Boolean]
    def redirect?
      status >= 300 && status < 400
    end

    # Check if response is a client error (4xx status)
    #
    # @return [Boolean]
    def client_error?
      status >= 400 && status < 500
    end

    # Check if response is a server error (5xx status)
    #
    # @return [Boolean]
    def server_error?
      status >= 500 && status < 600
    end

    # Check if response is any error (4xx or 5xx status)
    #
    # @return [Boolean]
    def error?
      status >= 400 && status < 600
    end

    # Get the Content-Type header
    #
    # @return [String, nil]
    def content_type
      headers["content-type"]
    end

    # Return true if Content-Type indicates JSON.
    #
    # @return [Boolean]
    def json?
      type = content_type.to_s.downcase
      type.match?(%r{\Aapplication/[^ ]*json\b}) || type == "text/json"
    end

    # Parse response body as JSON
    #
    # @return [Hash, Array] parsed JSON
    # @raise [RuntimeError] if Content-Type is not application/json
    # @raise [JSON::ParserError] if body is not valid JSON
    def json
      unless json?
        raise "Response Content-Type is not application/json (got: #{content_type.inspect})"
      end

      JSON.parse(body)
    end

    # Serialize to JSON hash.
    #
    # @return [Hash]
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

    # Serialize to JSON string.
    #
    # @param options [Hash] options to pass to JSON.generate (for ActiveSupport compatibility)
    # @return [String] JSON representation
    def to_json(options = nil)
      JSON.generate(as_json, options)
    end
  end
end
