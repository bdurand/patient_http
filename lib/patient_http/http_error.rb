# frozen_string_literal: true

module PatientHttp
  # Error raised when an HTTP request receives a non-2xx response status code
  # and the raise_error_responses option is enabled.
  #
  # This error includes the full Response object so you can access the status code,
  # headers, body, and other response data.
  class HttpError < Error
    # @return [Response] the HTTP response that triggered the error
    attr_reader :response

    class << self
      # Create a new HttpError (or subclass) from a response.
      #
      # The result is a ClientError for a 4xx response, a ServerError for a 5xx
      # response, or an HttpError for any other non-2xx response.
      #
      # @param response [Response] the HTTP response with non-2xx status code
      # @return [HttpError, ClientError, ServerError] the appropriate error instance
      def new(response)
        if response.client_error?
          ClientError.allocate.tap { |error| error.send(:initialize, response) }
        elsif response.server_error?
          ServerError.allocate.tap { |error| error.send(:initialize, response) }
        else
          super
        end
      end

      # Reconstruct an HttpError from a hash.
      #
      # @param hash [Hash] hash representation
      # @return [HttpError] reconstructed error
      def load(hash)
        response = Response.load(hash["response"])
        new(response)
      end
    end

    # Initialize a new HttpError.
    #
    # @param response [Response] the HTTP response with non-2xx status code
    def initialize(response)
      super("HTTP #{response.status} response from #{response.http_method.to_s.upcase} #{response.url}")
      @response = response
    end

    # Delegate the common response methods for convenience.
    #
    # @return [Integer] HTTP status code
    def status
      @response.status
    end

    # Return the error type symbol. Provided for compatibility with RequestError.
    #
    # @return [Symbol] the error type
    def error_type
      :http_error
    end

    def url
      response.url
    end

    def http_method
      response.http_method
    end

    def duration
      response.duration
    end

    def request_id
      response.request_id
    end

    def error_class
      self.class
    end

    def callback_args
      response.callback_args
    end

    # Convert to hash with string keys for serialization.
    #
    # @return [Hash] hash representation
    def as_json
      {
        "response" => @response.as_json
      }
    end
  end

  # Error raised when an HTTP request receives a 4xx (client error) response status code
  # and the raise_error_responses option is enabled.
  class ClientError < HttpError
  end

  # Error raised when an HTTP request receives a 5xx (server error) response status code
  # and the raise_error_responses option is enabled.
  class ServerError < HttpError
  end
end
