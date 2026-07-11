# frozen_string_literal: true

module PatientHttp
  # No-op task handler used for inline request execution.
  #
  # The {SynchronousExecutor} invokes the user callback directly, so the
  # completion and error hooks here are never exercised in practice; they are
  # defined as no-ops to satisfy the {TaskHandler} contract. Inline requests
  # have no job queue, so retrying is not supported.
  #
  # @api private
  class InlineTaskHandler < TaskHandler
    # @param response [Response] the HTTP response object
    # @param callback [String] callback class name
    # @return [void]
    def on_complete(response, callback)
    end

    # @param error [Error] the error object
    # @param callback [String] callback class name
    # @return [void]
    def on_error(error, callback)
    end

    # @raise [NotImplementedError] inline requests cannot be retried
    def retry
      raise NotImplementedError, "Inline requests cannot be retried"
    end
  end
end
