# frozen_string_literal: true

module PatientHttp
  # The error for a non-2xx response when the `raise_error_responses` option is
  # set.
  #
  # The error holds the full {Response}, so you can read the status, headers,
  # and body.
  class HttpError < Error
    # @return [Response] The HTTP response that caused the error.
    attr_reader :response

    class << self
      # Creates an error for a response. The status determines the class: a
      # {ClientError} for 4xx, a {ServerError} for 5xx, and an `HttpError` for
      # other non-2xx statuses.
      #
      # @param response [Response] The HTTP response with a non-2xx status.
      # @return [HttpError, ClientError, ServerError] The error.
      def new(response)
        if response.client_error?
          ClientError.allocate.tap { |error| error.send(:initialize, response) }
        elsif response.server_error?
          ServerError.allocate.tap { |error| error.send(:initialize, response) }
        else
          super
        end
      end

      # Creates an error from its serialized form.
      #
      # @param hash [Hash] The hash from {#as_json}.
      # @return [HttpError] The error.
      def load(hash)
        response = Response.load(hash["response"])
        new(response)
      end
    end

    # Creates an error.
    #
    # @param response [Response] The HTTP response with a non-2xx status.
    def initialize(response)
      super("HTTP #{response.status} response from #{response.http_method.to_s.upcase} #{response.url}")
      @response = response
    end

    # Returns the HTTP status of the response.
    #
    # @return [Integer] The HTTP status code.
    def status
      @response.status
    end

    # Returns the error type.
    #
    # @return [Symbol] Always `:http_error`.
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

    # @return [Float] The request duration in seconds.
    def duration
      response.duration
    end

    # @return [String] The unique request ID.
    def request_id
      response.request_id
    end

    # @return [Class] The class of this error.
    def error_class
      self.class
    end

    # @return [CallbackArgs] The callback arguments that were passed with the
    #   request.
    def callback_args
      response.callback_args
    end

    # Returns the error as a JSON-compatible hash.
    #
    # @return [Hash] The serialized error.
    def as_json
      {
        "response" => @response.as_json
      }
    end
  end

  # The error for a 4xx response when the `raise_error_responses` option is set.
  class ClientError < HttpError
  end

  # The error for a 5xx response when the `raise_error_responses` option is set.
  class ServerError < HttpError
  end
end
