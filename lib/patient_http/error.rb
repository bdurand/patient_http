# frozen_string_literal: true

module PatientHttp
  # Base error class for async HTTP errors. This is an abstract class that
  # defines the common error interface.
  class Error < StandardError
    class << self
      # Load an error from a hash, dispatching to the appropriate subclass.
      #
      # @param hash [Hash] hash representation of the error
      # @return [Error] the reconstructed error
      def load(hash)
        # Dispatch based on the hash structure.
        if hash.key?("response")
          HttpError.load(hash)
        elsif hash.key?("redirects")
          RedirectError.load(hash)
        else
          RequestError.load(hash)
        end
      end
    end

    # Return the error type symbol. Provided for compatibility with RequestError.
    #
    # @return [Symbol] the error type
    def error_type
      :unknown
    end

    # @return [String] request URL
    def url
      raise NotImplementedError, "Subclasses must implement #url"
    end

    # @return [Symbol] HTTP method
    def http_method
      raise NotImplementedError, "Subclasses must implement #http_method"
    end

    # @return [Float] request duration in seconds
    def duration
      raise NotImplementedError, "Subclasses must implement #duration"
    end

    # @return [String] unique request identifier
    def request_id
      raise NotImplementedError, "Subclasses must implement #request_id"
    end

    # @return [Class] the class of the exception that caused the error
    def error_class
      raise NotImplementedError, "Subclasses must implement #error_class"
    end

    # @return [CallbackArgs] the callback arguments
    def callback_args
      raise NotImplementedError, "Subclasses must implement #callback_args"
    end

    # Serialize to a hash for JSON encoding. Subclasses must implement this.
    #
    # @return [Hash] hash representation of the error
    def as_json
      raise NotImplementedError, "Subclasses must implement #as_json"
    end

    # Serialize to JSON string.
    #
    # @param options [Hash] options to pass to JSON.generate (for ActiveSupport compatibility)
    # @return [String] JSON representation
    def to_json(options = nil)
      JSON.generate(as_json, options)
    end
  end
end
