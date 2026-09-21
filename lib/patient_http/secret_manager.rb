# frozen_string_literal: true

module PatientHttp
  # Resolves {SecretReference} values into their secret values when the processor
  # sends a request.
  #
  # A SecretManager is built from the secrets that are registered on the
  # {Configuration}.
  #
  # @see Configuration#secret_manager
  class SecretManager
    # Raised when a referenced secret cannot be resolved.
    class SecretNotFoundError < StandardError; end

    # Initializes a new SecretManager.
    #
    # @param secrets [Hash{String => Object}] A registry that maps names to values. A
    #   value can be a callable, which runs with the name to produce the value.
    def initialize(secrets: {})
      @secrets = secrets || {}
    end

    # Checks whether a secret name is registered.
    #
    # @param name [String, Symbol] The secret name.
    # @return [Boolean] Whether the name is registered.
    def include?(name)
      @secrets.include?(name.to_s)
    end

    # Resolves a secret by name.
    #
    # If the registered value responds to `call`, it runs with the name.
    #
    # @param name [String, Symbol] The secret name.
    # @return [String] The resolved secret value.
    # @raise [SecretNotFoundError] If the secret cannot be resolved.
    def resolve(name)
      name = name.to_s

      unless @secrets.include?(name)
        raise SecretNotFoundError.new("No secret registered for #{name.inspect}")
      end

      value = @secrets[name]
      value = value.call(name) if value.respond_to?(:call)
      value&.to_s
    end

    # Resolves the secret references in a headers hash.
    #
    # @param headers [Hash, nil] The header name and value pairs.
    # @return [Hash, nil] A new hash, with each secret reference replaced by its
    #   resolved value.
    def resolve_headers(headers)
      resolve_values(headers)
    end

    # Resolves the secret references in a parameters hash.
    #
    # @param params [Hash, nil] The parameter name and value pairs.
    # @return [Hash, nil] A new hash, with each secret reference replaced by its
    #   resolved value.
    def resolve_params(params)
      resolve_values(params)
    end

    # Appends the resolved secret parameters to the query string of a URL.
    #
    # @param url [String] The request URL.
    # @param secret_params [Hash, nil] The secret parameter names and their
    #   {SecretReference} values.
    # @return [String] The URL with the resolved secret parameters appended. The URL
    #   is unchanged if there are no secret parameters.
    def resolve_url(url, secret_params)
      return url if secret_params.nil? || secret_params.empty?

      serialized_params = URI.encode_www_form(resolve_params(secret_params))
      uri = URI(url)
      uri.query = [uri.query, serialized_params].compact.reject(&:empty?).join("&")
      uri.to_s
    end

    private

    # Returns a new hash, with each secret reference value replaced by its resolved
    # value. A value that is not a secret is returned unchanged.
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
