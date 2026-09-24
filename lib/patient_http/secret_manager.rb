# frozen_string_literal: true

module PatientHttp
  # Replaces {SecretReference} values with the secret values when the processor
  # sends a request.
  #
  # The manager holds the secrets registered in the {Configuration}.
  #
  # @see Configuration#secret_manager
  class SecretManager
    # Raised when a referenced secret isn't registered.
    class SecretNotFoundError < StandardError; end

    # Creates a secret manager.
    #
    # @param secrets [Hash{String => Object}] The secret values, keyed by name. A
    #   value can be a callable, which is called with the name to get the value.
    def initialize(secrets: {})
      @secrets = secrets || {}
    end

    # Returns whether a secret is registered.
    #
    # @param name [String, Symbol] The secret name.
    # @return [Boolean] `true` if the secret is registered.
    def include?(name)
      @secrets.include?(name.to_s)
    end

    # Returns the value of a secret. If the registered value responds to `call`,
    # it's called with the name.
    #
    # @param name [String, Symbol] The secret name.
    # @return [String, nil] The secret value.
    # @raise [SecretNotFoundError] If the secret isn't registered.
    def resolve(name)
      name = name.to_s

      unless @secrets.include?(name)
        raise SecretNotFoundError.new("No secret registered for #{name.inspect}")
      end

      value = @secrets[name]
      value = value.call(name) if value.respond_to?(:call)
      value&.to_s
    end

    # Returns a copy of the headers with the secret references replaced by the
    # secret values.
    #
    # @param headers [Hash, nil] The headers.
    # @return [Hash, nil] The resolved headers.
    # @raise [SecretNotFoundError] If a referenced secret isn't registered.
    def resolve_headers(headers)
      resolve_values(headers)
    end

    # Returns a copy of the query parameters with the secret references
    # replaced by the secret values.
    #
    # @param params [Hash, nil] The query parameters.
    # @return [Hash, nil] The resolved query parameters.
    # @raise [SecretNotFoundError] If a referenced secret isn't registered.
    def resolve_params(params)
      resolve_values(params)
    end

    # Adds the resolved secret query parameters to a URL.
    #
    # @param url [String] The request URL.
    # @param secret_params [Hash, nil] The query parameters whose values are
    #   secret references.
    # @return [String] The URL with the parameters added. If there are no
    #   parameters, the URL is unchanged.
    # @raise [SecretNotFoundError] If a referenced secret isn't registered.
    def resolve_url(url, secret_params)
      return url if secret_params.nil? || secret_params.empty?

      serialized_params = URI.encode_www_form(resolve_params(secret_params))
      uri = URI(url)
      uri.query = [uri.query, serialized_params].compact.reject(&:empty?).join("&")
      uri.to_s
    end

    private

    # Returns a copy of a hash with the secret references replaced by the
    # secret values. Other values are unchanged.
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
