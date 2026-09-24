# frozen_string_literal: true

module PatientHttp
  # The task handler for requests that run inline.
  #
  # {SynchronousExecutor} calls the callback service directly, so
  # {#on_complete} and {#on_error} do nothing. Inline requests have no job
  # queue, so they can't be retried.
  #
  # @api private
  class InlineTaskHandler < TaskHandler
    # Does nothing.
    #
    # @param response [Response] The HTTP response.
    # @param callback [String] The callback service class name.
    # @return [void]
    def on_complete(response, callback)
    end

    # Does nothing.
    #
    # @param error [Error] The error.
    # @param callback [String] The callback service class name.
    # @return [void]
    def on_error(error, callback)
    end

    # Raises an error, because inline requests can't be retried.
    #
    # @raise [NotImplementedError] Always.
    def retry
      raise NotImplementedError, "Inline requests cannot be retried"
    end
  end
end
