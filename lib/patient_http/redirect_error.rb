# frozen_string_literal: true

module PatientHttp
  # The base class for redirect errors. A redirect error occurs when a request
  # exceeds the redirect limit or finds a redirect loop.
  class RedirectError < Error
    # @return [String] The request URL.
    attr_reader :url

    # @return [Symbol] The HTTP method.
    attr_reader :http_method

    # @return [Float] The request duration in seconds.
    attr_reader :duration

    # @return [String] The unique request ID.
    attr_reader :request_id

    # @return [Array<String>] The URLs of the redirects that were followed, in
    #   order.
    attr_reader :redirects

    class << self
      # Creates an error from its serialized form.
      #
      # @param hash [Hash] The hash from {#as_json}.
      # @return [RedirectError] The error.
      # @raise [ArgumentError] If the serialized error class isn't a
      #   `RedirectError`.
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

    # Creates an error.
    #
    # @param message [String] The error message.
    # @param url [String] The request URL.
    # @param http_method [Symbol, String] The HTTP method.
    # @param duration [Float] The request duration in seconds.
    # @param request_id [String] The unique request ID.
    # @param redirects [Array<String>] The URLs of the redirects that were
    #   followed.
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
    # @return [Symbol] Always `:redirect`.
    def error_type
      :redirect
    end

    # @return [Class] The class of this error.
    def error_class
      self.class
    end

    # Returns the callback arguments that were passed with the request.
    #
    # @return [CallbackArgs] The callback arguments.
    def callback_args
      @callback_args ||= CallbackArgs.load(@callback_args_data)
    end

    # Returns the error as a JSON-compatible hash.
    #
    # @return [Hash] The serialized error.
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

  # The error for a request that exceeds the redirect limit.
  class TooManyRedirectsError < RedirectError
    # Creates an error.
    #
    # @param url [String] The URL of the redirect that exceeded the limit.
    # @param http_method [Symbol, String] The HTTP method.
    # @param duration [Float] The request duration in seconds.
    # @param request_id [String] The unique request ID.
    # @param redirects [Array<String>] The URLs of the redirects that were
    #   followed.
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

  # The error for a redirect loop, where a redirect goes to a URL that the
  # request already visited.
  class RecursiveRedirectError < RedirectError
    # Creates an error.
    #
    # @param url [String] The URL that caused the loop.
    # @param http_method [Symbol, String] The HTTP method.
    # @param duration [Float] The request duration in seconds.
    # @param request_id [String] The unique request ID.
    # @param redirects [Array<String>] The URLs of the redirects that were
    #   followed.
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
