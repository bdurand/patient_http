# frozen_string_literal: true

module PatientHttp
  # Error raised when an HTTP request receives a non-2xx response status code and the
  # `raise_error_responses` option is enabled.
  #
  # This error holds the full {Response}, so you can read the status code, headers,
  # body, and other response data.
  class HttpError < Error
    # @return [Response] The HTTP response that caused the error.
    attr_reader :response

    class << self
      # Creates a new HttpError, or a subclass of it, from a response.
      #
      # This method returns a {ClientError} for a 4xx response, a {ServerError} for a
      # 5xx response, and an HttpError for any other non-2xx response.
      #
      # @param response [Response] The HTTP response with a non-2xx status code.
      # @return [HttpError, ClientError, ServerError] The matching error.
      def new(response)
        if response.client_error?
          ClientError.allocate.tap { |error| error.send(:initialize, response) }
        elsif response.server_error?
          ServerError.allocate.tap { |error| error.send(:initialize, response) }
        else
          super
        end
      end

      # Reconstructs an HttpError from a hash.
      #
      # @param hash [Hash] The hash representation.
      # @return [HttpError] The reconstructed error.
      def load(hash)
        response = Response.load(hash["response"])
        new(response)
      end
    end

    # Initializes a new HttpError.
    #
    # @param response [Response] The HTTP response with a non-2xx status code.
    def initialize(response)
      super("HTTP #{response.status} response from #{response.http_method.to_s.upcase} #{response.url}")
      @response = response
    end

    # Returns the HTTP status code of the response.
    #
    # @return [Integer] The HTTP status code.
    def status
      @response.status
    end

    # Returns the error type. This method exists for compatibility with
    # {RequestError}.
    #
    # @return [Symbol] The error type.
    def error_type
      :http_error
    end

    # @return [String] The request URL.
    def url
      response.url
    end

    # @return [Symbol] The HTTP method.
    def http_method
      response.http_method
    end

    # @return [Float] The request duration, in seconds.
    def duration
      response.duration
    end

    # @return [String] The unique request identifier.
    def request_id
      response.request_id
    end

    # @return [Class] The class of the error.
    def error_class
      self.class
    end

    # @return [CallbackArgs] The callback arguments.
    def callback_args
      response.callback_args
    end

    # Converts the error to a hash with string keys for serialization.
    #
    # @return [Hash] The hash representation.
    def as_json
      {
        "response" => @response.as_json
      }
    end
  end

  # Error raised when an HTTP request receives a 4xx (client error) response status
  # code and the `raise_error_responses` option is enabled.
  class ClientError < HttpError
  end

  # Error raised when an HTTP request receives a 5xx (server error) response status
  # code and the `raise_error_responses` option is enabled.
  class ServerError < HttpError
  end
end
