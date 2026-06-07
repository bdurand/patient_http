# frozen_string_literal: true

module PatientHttp
  # Resolves {SecretReference} values into their actual secret values when a request
  # is sent by the processor.
  #
  # A SecretManager is built from the secrets registered on the {Configuration}.
  #
  # @see Configuration#secret_manager
  class SecretManager
    # Raised when a referenced secret cannot be resolved.
    class SecretNotFoundError < StandardError; end

    # Initialize a new SecretManager.
    #
    # @param secrets [Hash{String => Object}] static registry mapping names to values
    #   (a value may be a callable, which is invoked with the name to produce the value)
    #   secret not found in the static registry
    def initialize(secrets: {})
      @secrets = secrets || {}
    end

    # Check if a secret name is registered in the static registry.
    #
    # @param name [String, Symbol] the secret name
    # @return [Boolean] true if the name is registered, false otherwise
    def include?(name)
      @secrets.include?(name.to_s)
    end

    # Resolve a secret by name.
    #
    # The static registry is checked first; if the registered value responds to #call
    # it is invoked with the name. If the name is not in the registry, an error is raised.
    #
    # @param name [String, Symbol] the secret name
    # @return [String] the resolved secret value
    # @raise [SecretNotFoundError] if the secret cannot be resolved
    def resolve(name)
      name = name.to_s

      unless @secrets.include?(name)
        raise SecretNotFoundError.new("No secret registered for #{name.inspect}")
      end

      value = @secrets[name]
      value = value.call(name) if value.respond_to?(:call)
      value&.to_s
    end

    # Resolve any secret references in a headers hash, returning a new hash.
    #
    # @param headers [Hash, nil] header name/value pairs
    # @return [Hash, nil] a new hash with secret references replaced by resolved values
    def resolve_headers(headers)
      resolve_values(headers)
    end

    # Resolve any secret references in a params hash, returning a new hash.
    #
    # @param params [Hash, nil] param name/value pairs
    # @return [Hash, nil] a new hash with secret references replaced by resolved values
    def resolve_params(params)
      resolve_values(params)
    end

    # Append resolved secret params to a URL's query string.
    #
    # @param url [String] the request URL
    # @param secret_params [Hash, nil] secret param name/value (SecretReference) pairs
    # @return [String] the URL with resolved secret params appended (unchanged if none)
    def resolve_url(url, secret_params)
      return url if secret_params.nil? || secret_params.empty?

      serialized_params = URI.encode_www_form(resolve_params(secret_params))
      uri = URI(url)
      uri.query = [uri.query, serialized_params].compact.reject(&:empty?).join("&")
      uri.to_s
    end

    private

    # Return a new hash with any secret-reference values replaced by their resolved
    # values. Non-secret values are passed through unchanged.
    def resolve_values(hash)
      return hash if hash.nil?

      hash.each_with_object({}) do |(key, value), result|
        result[key] = if SecretReference.reference?(value)
          resolve(SecretReference.load(value).name)
        else
          value
        end
      end
    end
  end
end
