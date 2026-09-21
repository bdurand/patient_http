# frozen_string_literal: true

module PatientHttp
  # Base error class for async HTTP errors.
  #
  # @abstract This class defines the error interface that every error shares.
  class Error < StandardError
    class << self
      # Loads an error from a hash and dispatches to the matching subclass.
      #
      # @param hash [Hash] The hash representation of the error.
      # @return [Error] The reconstructed error.
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

    # Returns the error type. This method exists for compatibility with
    # {RequestError}.
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

    # @return [Float] The request duration, in seconds.
    def duration
      raise NotImplementedError, "Subclasses must implement #duration"
    end

    # @return [String] The unique request identifier.
    def request_id
      raise NotImplementedError, "Subclasses must implement #request_id"
    end

    # @return [Class] The class of the exception that caused the error.
    def error_class
      raise NotImplementedError, "Subclasses must implement #error_class"
    end

    # @return [CallbackArgs] The callback arguments.
    def callback_args
      raise NotImplementedError, "Subclasses must implement #callback_args"
    end

    # Serializes the error to a hash for JSON encoding. Subclasses must implement this
    # method.
    #
    # @return [Hash] The hash representation of the error.
    def as_json
      raise NotImplementedError, "Subclasses must implement #as_json"
    end

    # Serializes the error to a JSON string.
    #
    # @param options [Hash] The options to pass to `JSON.generate`. This parameter
    #   exists for compatibility with ActiveSupport.
    # @return [String] The JSON representation.
    def to_json(options = nil)
      JSON.generate(as_json, options)
    end
  end
end
