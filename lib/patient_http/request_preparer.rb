# frozen_string_literal: true

module PatientHttp
  # Prepares a {Request} to be sent. The preparer resolves secret references, sets
  # the send-time headers `x-request-id` and the default `user-agent`, and calls
  # the preprocessors attached to the request.
  class RequestPreparer
    # Raised when a request references a preprocessor name that isn't registered.
    class PreprocessorNotFoundError < StandardError; end

    # Creates a request preparer.
    #
    # @param config [Configuration] The configuration with the secrets and preprocessors.
    def initialize(config)
      @config = config
    end

    # Prepares a request for sending.
    #
    # This method resolves secret references in the headers and query parameters,
    # and then sets the `x-request-id` and default `user-agent` headers. Finally, it
    # calls each preprocessor attached to the request, in order, with the outgoing
    # request. Each preprocessor sees the changes made by the ones before it.
    #
    # @param request [Request] The request to prepare.
    # @param request_id [String] The unique request identifier. It's sent as the
    #   `x-request-id` header.
    # @return [OutgoingRequest] The outgoing request with the final URL and headers.
    # @raise [PreprocessorNotFoundError] If the request references an unregistered preprocessor.
    def prepare(request, request_id)
      headers = @config.secret_manager.resolve_headers(request.headers.to_h)
      headers["x-request-id"] = request_id
      headers["user-agent"] ||= @config.user_agent if @config.user_agent
      # Compressed responses are inflated by ResponseReader during response
      # decoding rather than by a client middleware wrapper. Requesting gzip is
      # the default because it is what the reader can decode, but a caller that
      # sets the header keeps its own value: "identity" opts out of compression,
      # and any other encoding is delivered still encoded with its
      # content-encoding header intact.
      headers["accept-encoding"] ||= "gzip"
      url = @config.secret_manager.resolve_url(request.url, request.secret_params)

      outgoing = OutgoingRequest.new(
        http_method: request.http_method,
        url: url,
        headers: HttpHeaders.new(headers),
        body: request.body
      )

      request.preprocessors.each do |name|
        preprocessor = @config.preprocessor(name)
        unless preprocessor
          raise PreprocessorNotFoundError.new("No preprocessor registered for #{name.inspect}")
        end

        preprocessor.call(outgoing)
      end

      outgoing
    end
  end
end
