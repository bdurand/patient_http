# frozen_string_literal: true

module PatientHttp
  # A task handler that does nothing, for inline request execution.
  #
  # {SynchronousExecutor} invokes the user callback directly, so these completion
  # and error hooks never run. They exist only to satisfy the {TaskHandler}
  # contract. Inline requests have no job queue, so they can't be retried.
  #
  # @api private
  class InlineTaskHandler < TaskHandler
    # Does nothing.
    #
    # @param response [Response] The HTTP response.
    # @param callback [String] The callback class name.
    # @return [void]
    def on_complete(response, callback)
    end

    # Does nothing.
    #
    # @param error [Error] The error.
    # @param callback [String] The callback class name.
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
