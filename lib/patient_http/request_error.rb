# frozen_string_literal: true

module PatientHttp
  # Error object representing an exception from making an HTTP request. Note that this
  # is not for HTTP error responses (4xx/5xx), but from actual exceptions raised
  # during the request (timeouts, connection errors, SSL errors, etc).
  #
  # This is how errors are passed back to the error continuation jobs for processing.
  class RequestError < Error
    # Valid error types
    ERROR_TYPES = [:timeout, :connection, :ssl, :response_too_large, :unknown].freeze

    # @return [String] Request URL
    attr_reader :url

    # @return [Symbol] HTTP method
    attr_reader :http_method

    # @return [Float] Request duration in seconds
    attr_reader :duration

    # @return [String] Unique request identifier
    attr_reader :request_id

    # @return [Symbol] Categorized error type. This provides a higher level categorization
    # of the error (e.g., :connection is used to group IO and socket errors).
    attr_reader :error_type

    class << self
      # Reconstruct a RequestError from a hash
      #
      # @param hash [Hash] hash representation
      # @return [RequestError] reconstructed error
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

      # Create a RequestError from an exception using pattern matching
      #
      # @param exception [Exception] the exception to convert
      # @param duration [Float] request duration in seconds
      # @param request_id [String] the request ID
      # @param url [String] the request URL
      # @param http_method [Symbol, String] the HTTP method
      # @param callback_args [Hash, nil] callback arguments (string keys)
      # @return [RequestError] the error object
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

      # Determine error type from exception.
      #
      # @param exception [Exception] the exception to categorize
      # @return [Symbol] the error type
      def error_type(exception)
        case exception
        in Async::TimeoutError
          :timeout
        in OpenSSL::SSL::SSLError
          :ssl
        in Errno::ECONNREFUSED | Errno::ECONNRESET | Errno::ECONNABORTED | Errno::EHOSTUNREACH | Errno::EPIPE | SocketError | IOError
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
    # @param class_name [String] Name of the exception class
    # @param message [String] Exception message
    # @param backtrace [Array<String>] Exception backtrace
    # @param error_type [Symbol] Categorized error type
    # @param duration [Float] Request duration in seconds
    # @param request_id [String] Unique request identifier
    # @param url [String] Request URL
    # @param http_method [Symbol, String] HTTP method
    # @param callback_args [Hash, nil] callback arguments (string keys)
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

    # Convert to hash with string keys for serialization
    #
    # @return [Hash] hash representation
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

    # Get the actual Exception class constant from the class_name
    #
    # @return [Class, nil] the exception class or nil if not found
    def error_class
      ClassHelper.resolve_class_name(@class_name)
    end

    # Returns the callback arguments as a CallbackArgs object.
    #
    # @return [CallbackArgs] the callback arguments
    def callback_args
      @callback_args ||= CallbackArgs.load(@callback_args_data)
    end
  end
end
