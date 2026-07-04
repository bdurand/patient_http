# frozen_string_literal: true

module PatientHttp
  # Base class for redirect-related errors.
  # These errors occur when redirect handling fails due to too many redirects
  # or a redirect loop.
  class RedirectError < Error
    # @return [String] Request URL
    attr_reader :url

    # @return [Symbol] HTTP method
    attr_reader :http_method

    # @return [Float] Request duration in seconds
    attr_reader :duration

    # @return [String] Unique request identifier
    attr_reader :request_id

    # @return [Array<String>] URLs that were visited during redirect chain
    attr_reader :redirects

    class << self
      # Reconstruct a RedirectError from a hash
      #
      # @param hash [Hash] hash representation
      # @return [RedirectError] reconstructed error
      # @raise [ArgumentError] if the serialized error class is not a RedirectError
      def load(hash)
        error_class = ClassHelper.resolve_class_name(hash["error_class"])
        unless error_class.is_a?(Class) && error_class <= RedirectError
          raise ArgumentError.new("Invalid redirect error class: #{hash["error_class"].inspect}")
        end

        error_class.new(
          url: hash["url"],
          http_method: hash["http_method"]&.to_sym,
          duration: hash["duration"],
          request_id: hash["request_id"],
          redirects: hash["redirects"] || [],
          callback_args: hash["callback_args"]
        )
      end
    end

    # Initializes a new RedirectError.
    #
    # @param message [String] Error message
    # @param url [String] Request URL
    # @param http_method [Symbol, String] HTTP method
    # @param duration [Float] Request duration in seconds
    # @param request_id [String] Unique request identifier
    # @param redirects [Array<String>] URLs visited during redirect chain
    # @param callback_args [Hash, nil] callback arguments (string keys)
    def initialize(message, url:, http_method:, duration:, request_id:, redirects:, callback_args: nil)
      super(message)
      @url = url
      @http_method = http_method&.to_sym
      @duration = duration
      @request_id = request_id
      @redirects = redirects || []
      @callback_args_data = callback_args || {}
    end

    # Returns the error type symbol.
    #
    # @return [Symbol] the error type
    def error_type
      :redirect
    end

    # @return [Class] the class of the exception. This is for compatibility with RequestError.
    def error_class
      self.class
    end

    # Returns the callback arguments as a CallbackArgs object.
    #
    # @return [CallbackArgs] the callback arguments
    def callback_args
      @callback_args ||= CallbackArgs.load(@callback_args_data)
    end

    # Convert to hash with string keys for serialization
    #
    # @return [Hash] hash representation
    def as_json
      {
        "error_class" => self.class.name,
        "url" => url,
        "http_method" => http_method.to_s,
        "duration" => duration,
        "request_id" => request_id,
        "redirects" => redirects,
        "callback_args" => @callback_args_data
      }
    end
  end

  # Error raised when too many redirects are encountered.
  class TooManyRedirectsError < RedirectError
    # @param url [String] The URL that would have been redirected to
    # @param http_method [Symbol, String] HTTP method
    # @param duration [Float] Request duration in seconds
    # @param request_id [String] Unique request identifier
    # @param redirects [Array<String>] URLs visited during redirect chain
    # @param callback_args [Hash, nil] callback arguments (string keys)
    def initialize(url:, http_method:, duration:, request_id:, redirects:, callback_args: nil)
      super(
        "Too many redirects (#{redirects.size}) while requesting #{http_method.to_s.upcase} #{redirects.first || url}",
        url: url,
        http_method: http_method,
        duration: duration,
        request_id: request_id,
        redirects: redirects,
        callback_args: callback_args
      )
    end
  end

  # Error raised when a recursive redirect is detected.
  class RecursiveRedirectError < RedirectError
    # @param url [String] The URL that caused the loop
    # @param http_method [Symbol, String] HTTP method
    # @param duration [Float] Request duration in seconds
    # @param request_id [String] Unique request identifier
    # @param redirects [Array<String>] URLs visited during redirect chain
    # @param callback_args [Hash, nil] callback arguments (string keys)
    def initialize(url:, http_method:, duration:, request_id:, redirects:, callback_args: nil)
      super(
        "Recursive redirect detected: #{url} was already visited in redirect chain",
        url: url,
        http_method: http_method,
        duration: duration,
        request_id: request_id,
        redirects: redirects,
        callback_args: callback_args
      )
    end
  end
end
