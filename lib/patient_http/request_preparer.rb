# frozen_string_literal: true

module PatientHttp
  # Prepares a {Request} to be sent: resolves any secret references, sets the
  # send-time headers (x-request-id and the default user-agent), and invokes any
  # preprocessors attached to the request.
  class RequestPreparer
    # Raised when a request references a preprocessor name that is not registered.
    class PreprocessorNotFoundError < StandardError; end

    # @param config [Configuration] the configuration holding secrets and preprocessors
    def initialize(config)
      @config = config
    end

    # Prepare a request for sending.
    #
    # Secret references in the headers and query params are resolved first, then the
    # x-request-id and default user-agent headers are set, and finally each
    # preprocessor attached to the request is invoked in order with the outgoing
    # request. Each preprocessor sees any changes made by the ones before it.
    #
    # @param request [Request] the request to prepare
    # @param request_id [String] unique request identifier set as the x-request-id header
    # @return [OutgoingRequest] the outgoing request with the final URL and headers
    # @raise [PreprocessorNotFoundError] if the request references an unregistered preprocessor
    def prepare(request, request_id)
      headers = @config.secret_manager.resolve_headers(request.headers.to_h)
      headers["x-request-id"] = request_id
      headers["user-agent"] ||= @config.user_agent if @config.user_agent
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
