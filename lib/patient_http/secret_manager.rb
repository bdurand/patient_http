# frozen_string_literal: true

module PatientHttp
  # Resolves {SecretReference} values to their secret values when the processor
  # sends a request.
  #
  # A secret manager is built from the secrets registered on the {Configuration}.
  #
  # @see Configuration#secret_manager
  class SecretManager
    # Raised when a referenced secret can't be resolved.
    class SecretNotFoundError < StandardError; end

    # Creates a secret manager.
    #
    # @param secrets [Hash{String => Object}] A registry that maps names to values. A value
    #   can be a callable, which is called with the name to produce the value.
    def initialize(secrets: {})
      @secrets = secrets || {}
    end

    # Returns `true` if a secret name is registered.
    #
    # @param name [String, Symbol] The secret name.
    # @return [Boolean] `true` if the name is registered, or `false` otherwise.
    def include?(name)
      @secrets.include?(name.to_s)
    end

    # Resolves a secret by name.
    #
    # If the registered value responds to `call`, it's called with the name. If the
    # name isn't registered, this method raises an error.
    #
    # @param name [String, Symbol] The secret name.
    # @return [String] The resolved secret value.
    # @raise [SecretNotFoundError] If the secret can't be resolved.
    def resolve(name)
      name = name.to_s

      unless @secrets.include?(name)
        raise SecretNotFoundError.new("No secret registered for #{name.inspect}")
      end

      value = @secrets[name]
      value = value.call(name) if value.respond_to?(:call)
      value&.to_s
    end

    # Resolves the secret references in a headers hash and returns a new hash.
    #
    # @param headers [Hash, nil] The header names and values.
    # @return [Hash, nil] A new hash with secret references replaced by resolved values.
    def resolve_headers(headers)
      resolve_values(headers)
    end

    # Resolves the secret references in a query parameters hash and returns a new hash.
    #
    # @param params [Hash, nil] The parameter names and values.
    # @return [Hash, nil] A new hash with secret references replaced by resolved values.
    def resolve_params(params)
      resolve_values(params)
    end

    # Appends resolved secret query parameters to a URL's query string.
    #
    # @param url [String] The request URL.
    # @param secret_params [Hash, nil] The secret parameter names and {SecretReference} values.
    # @return [String] The URL with the resolved secret parameters appended. If there are
    #   no secret parameters, the URL is unchanged.
    def resolve_url(url, secret_params)
      return url if secret_params.nil? || secret_params.empty?

      serialized_params = URI.encode_www_form(resolve_params(secret_params))
      uri = URI(url)
      uri.query = [uri.query, serialized_params].compact.reject(&:empty?).join("&")
      uri.to_s
    end

    private

    # Returns a new hash with secret reference values replaced by their resolved
    # values. Other values stay unchanged.
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
