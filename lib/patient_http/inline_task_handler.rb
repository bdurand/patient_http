# frozen_string_literal: true

module PatientHttp
  # Task handler that does nothing, used for inline request execution.
  #
  # The {SynchronousExecutor} calls the user callback directly, so the completion and
  # error hooks here never run in practice. They exist only to satisfy the
  # {TaskHandler} contract. Inline requests have no job queue, so they cannot be
  # retried.
  #
  # @api private
  class InlineTaskHandler < TaskHandler
    # @param response [Response] The HTTP response.
    # @param callback [String] The callback class name.
    # @return [void]
    def on_complete(response, callback)
    end

    # @param error [Error] The error.
    # @param callback [String] The callback class name.
    # @return [void]
    def on_error(error, callback)
    end

    # @raise [NotImplementedError] Inline requests cannot be retried.
    def retry
      raise NotImplementedError, "Inline requests cannot be retried"
    end
  end
end
