# frozen_string_literal: true

module PatientHttp
  # Base class for redirect errors.
  #
  # These errors occur when redirect handling fails because there are too many
  # redirects or because the redirects form a loop.
  class RedirectError < Error
    # @return [String] The request URL.
    attr_reader :url

    # @return [Symbol] The HTTP method.
    attr_reader :http_method

    # @return [Float] The request duration, in seconds.
    attr_reader :duration

    # @return [String] The unique request identifier.
    attr_reader :request_id

    # @return [Array<String>] The URLs that were visited in the redirect chain.
    attr_reader :redirects

    class << self
      # Reconstructs a RedirectError from a hash.
      #
      # @param hash [Hash] The hash representation.
      # @return [RedirectError] The reconstructed error.
      # @raise [ArgumentError] If the serialized error class is not a RedirectError.
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
    # @param message [String] The error message.
    # @param url [String] The request URL.
    # @param http_method [Symbol, String] The HTTP method.
    # @param duration [Float] The request duration, in seconds.
    # @param request_id [String] The unique request identifier.
    # @param redirects [Array<String>] The URLs that were visited in the redirect
    #   chain.
    # @param callback_args [Hash, nil] The callback arguments, with string keys.
    def initialize(message, url:, http_method:, duration:, request_id:, redirects:, callback_args: nil)
      super(message)
      @url = url
      @http_method = http_method&.to_sym
      @duration = duration
      @request_id = request_id
      @redirects = redirects || []
      @callback_args_data = callback_args || {}
    end

    # Returns the error type.
    #
    # @return [Symbol] The error type.
    def error_type
      :redirect
    end

    # @return [Class] The class of the exception. This method exists for compatibility
    #   with {RequestError}.
    def error_class
      self.class
    end

    # Returns the callback arguments as a {CallbackArgs} object.
    #
    # @return [CallbackArgs] The callback arguments.
    def callback_args
      @callback_args ||= CallbackArgs.load(@callback_args_data)
    end

    # Converts the error to a hash with string keys for serialization.
    #
    # @return [Hash] The hash representation.
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

  # Error raised when a request encounters too many redirects.
  class TooManyRedirectsError < RedirectError
    # Initializes a new TooManyRedirectsError.
    #
    # @param url [String] The URL that the request would have been redirected to.
    # @param http_method [Symbol, String] The HTTP method.
    # @param duration [Float] The request duration, in seconds.
    # @param request_id [String] The unique request identifier.
    # @param redirects [Array<String>] The URLs that were visited in the redirect
    #   chain.
    # @param callback_args [Hash, nil] The callback arguments, with string keys.
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

  # Error raised when the redirects form a loop.
  class RecursiveRedirectError < RedirectError
    # Initializes a new RecursiveRedirectError.
    #
    # @param url [String] The URL that caused the loop.
    # @param http_method [Symbol, String] The HTTP method.
    # @param duration [Float] The request duration, in seconds.
    # @param request_id [String] The unique request identifier.
    # @param redirects [Array<String>] The URLs that were visited in the redirect
    #   chain.
    # @param callback_args [Hash, nil] The callback arguments, with string keys.
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
