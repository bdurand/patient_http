# frozen_string_literal: true

module PatientHttp
  # The abstract base class for errors that a request passes to the `on_error`
  # callback. It defines the methods that all of these errors have.
  #
  # The subclasses are {HttpError}, {RedirectError}, and {RequestError}.
  class Error < StandardError
    class << self
      # Creates an error from its serialized form. The hash determines the
      # subclass.
      #
      # @param hash [Hash] The hash from {#as_json}.
      # @return [Error] The error.
      def load(hash)
        # Dispatch based on hash structure
        if hash.key?("response")
          HttpError.load(hash)
        elsif hash.key?("redirects")
          RedirectError.load(hash)
        else
          RequestError.load(hash)
        end
      end
    end

    # Returns the error type. Subclasses return a more specific value.
    #
    # @return [Symbol] The error type.
    def error_type
      :unknown
    end

    # @return [String] The request URL.
    def url
      raise NotImplementedError, "Subclasses must implement #url"
    end

    # @return [Symbol] The HTTP method.
    def http_method
      raise NotImplementedError, "Subclasses must implement #http_method"
    end

    # @return [Float] The request duration in seconds.
    def duration
      raise NotImplementedError, "Subclasses must implement #duration"
    end

    # @return [String] The unique request ID.
    def request_id
      raise NotImplementedError, "Subclasses must implement #request_id"
    end

    # @return [Class] The class of the exception that caused the error.
    def error_class
      raise NotImplementedError, "Subclasses must implement #error_class"
    end

    # @return [CallbackArgs] The callback arguments that were passed with the
    #   request.
    def callback_args
      raise NotImplementedError, "Subclasses must implement #callback_args"
    end

    # Returns the error as a JSON-compatible hash. Subclasses must implement
    # this method.
    #
    # @return [Hash] The serialized error.
    def as_json
      raise NotImplementedError, "Subclasses must implement #as_json"
    end

    # Returns the error as a JSON string.
    #
    # @param options [Hash, nil] The options for `JSON.generate`. This parameter
    #   makes the method compatible with Active Support.
    # @return [String] The JSON string.
    def to_json(options = nil)
      JSON.generate(as_json, options)
    end
  end
end
