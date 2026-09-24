# frozen_string_literal: true

module PatientHttp
  # Raised when an HTTP request receives a non-2xx response status code and the
  # `raise_error_responses` option is enabled.
  #
  # The error includes the full {Response}, so you can access the status code,
  # headers, body, and other response data.
  class HttpError < Error
    # @return [Response] The HTTP response that triggered the error.
    attr_reader :response

    class << self
      # Creates an error from a response.
      #
      # Returns a {ClientError} for 4xx responses, a {ServerError} for 5xx responses,
      # and an {HttpError} for other non-2xx responses.
      #
      # @param response [Response] The HTTP response with a non-2xx status code.
      # @return [HttpError, ClientError, ServerError] The appropriate error instance.
      def new(response)
        if response.client_error?
          ClientError.allocate.tap { |error| error.send(:initialize, response) }
        elsif response.server_error?
          ServerError.allocate.tap { |error| error.send(:initialize, response) }
        else
          super
        end
      end

      # Reconstructs an error from a hash.
      #
      # @param hash [Hash] The hash representation.
      # @return [HttpError] The reconstructed error.
      def load(hash)
        response = Response.load(hash["response"])
        new(response)
      end
    end

    # Creates an error for a response.
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

    # Returns the error type. This method provides compatibility with {RequestError}.
    #
    # @return [Symbol] The error type.
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

    # Converts the error to a hash with string keys for serialization.
    #
    # @return [Hash] The hash representation.
    def as_json
      {
        "response" => @response.as_json
      }
    end
  end

  # Raised when an HTTP request receives a 4xx (client error) response status code
  # and the `raise_error_responses` option is enabled.
  class ClientError < HttpError
  end

  # Raised when an HTTP request receives a 5xx (server error) response status code
  # and the `raise_error_responses` option is enabled.
  class ServerError < HttpError
  end
end
