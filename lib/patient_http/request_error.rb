# frozen_string_literal: true

module PatientHttp
  # Error that represents an exception from making an HTTP request.
  #
  # This error is not for HTTP error responses (4xx and 5xx). It is for the exceptions
  # that are raised during a request, such as timeouts, connection errors, and SSL
  # errors. Errors reach the error continuation jobs in this form.
  class RequestError < Error
    # The valid error types.
    ERROR_TYPES = [:timeout, :connection, :ssl, :response_too_large, :unknown].freeze

    # @return [String] The request URL.
    attr_reader :url

    # @return [Symbol] The HTTP method.
    attr_reader :http_method

    # @return [Float] The request duration, in seconds.
    attr_reader :duration

    # @return [String] The unique request identifier.
    attr_reader :request_id

    # @return [Symbol] The error category. This is a higher level grouping of the
    #   error. For example, `:connection` groups IO errors and socket errors.
    attr_reader :error_type

    class << self
      # Reconstructs a RequestError from a hash.
      #
      # @param hash [Hash] The hash representation.
      # @return [RequestError] The reconstructed error.
      def load(hash)
        new(
          class_name: hash["class_name"],
          message: hash["message"],
          backtrace: hash["backtrace"],
          request_id: hash["request_id"],
          error_type: hash["error_type"]&.to_sym,
          duration: hash["duration"],
          url: hash["url"],
          http_method: hash["http_method"],
          callback_args: hash["callback_args"]
        )
      end

      # Creates a RequestError from an exception.
      #
      # @param exception [Exception] The exception to convert.
      # @param duration [Float] The request duration, in seconds.
      # @param request_id [String] The request ID.
      # @param url [String] The request URL.
      # @param http_method [Symbol, String] The HTTP method.
      # @param callback_args [Hash, nil] The callback arguments, with string keys.
      # @return [RequestError] The error.
      def from_exception(exception, duration:, request_id:, url:, http_method:, callback_args: nil)
        type = error_type(exception)

        new(
          class_name: exception.class.name,
          message: exception.message,
          backtrace: exception.backtrace || [],
          request_id: request_id,
          error_type: type,
          duration: duration,
          url: url,
          http_method: http_method,
          callback_args: callback_args
        )
      end

      # Returns the error type for an exception.
      #
      # @param exception [Exception] The exception to categorize.
      # @return [Symbol] The error type.
      def error_type(exception)
        case exception
        in Async::TimeoutError
          :timeout
        in OpenSSL::SSL::SSLError
          :ssl
        in Errno::ECONNREFUSED | Errno::ECONNRESET | Errno::ECONNABORTED | Errno::EHOSTUNREACH | Errno::ETIMEDOUT | Errno::EPIPE | SocketError | IOError
          :connection
        else
          if exception.is_a?(PatientHttp::ResponseTooLargeError)
            :response_too_large
          else
            :unknown
          end
        end
      end
    end

    # Initializes a new RequestError.
    #
    # @param class_name [String] The name of the exception class.
    # @param message [String] The exception message.
    # @param backtrace [Array<String>] The exception backtrace.
    # @param error_type [Symbol] The error category.
    # @param duration [Float] The request duration, in seconds.
    # @param request_id [String] The unique request identifier.
    # @param url [String] The request URL.
    # @param http_method [Symbol, String] The HTTP method.
    # @param callback_args [Hash, nil] The callback arguments, with string keys.
    def initialize(class_name:, message:, backtrace:, error_type:, duration:, request_id:, url:, http_method:,
      callback_args: nil)
      super(message)
      set_backtrace(backtrace)
      @class_name = class_name
      @error_type = error_type
      @duration = duration
      @request_id = request_id
      @url = url
      @http_method = http_method&.to_sym
      @callback_args_data = callback_args || {}
    end

    # Converts the error to a hash with string keys for serialization.
    #
    # @return [Hash] The hash representation.
    def as_json
      {
        "class_name" => @class_name,
        "message" => message,
        "backtrace" => backtrace,
        "request_id" => request_id,
        "error_type" => error_type.to_s,
        "duration" => duration,
        "url" => url,
        "http_method" => http_method.to_s,
        "callback_args" => @callback_args_data
      }
    end

    # Returns the exception class for the serialized class name.
    #
    # @return [Class, nil] The exception class, or nil if it is not found.
    def error_class
      ClassHelper.resolve_class_name(@class_name)
    end

    # Returns the callback arguments as a {CallbackArgs} object.
    #
    # @return [CallbackArgs] The callback arguments.
    def callback_args
      @callback_args ||= CallbackArgs.load(@callback_args_data)
    end
  end
end
