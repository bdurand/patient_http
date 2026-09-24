# frozen_string_literal: true

module PatientHttp
  # The abstract base class for task lifecycle operations.
  #
  # A task handler connects {RequestTask} to a job system, so request tasks don't
  # depend on any specific job system. Implementations handle completion callbacks,
  # error callbacks, and job retries.
  #
  # @abstract Subclass and implement all methods to create a concrete handler.
  #
  # @example Creating a custom handler
  #   class MyTaskHandler < PatientHttp::TaskHandler
  #     def on_complete(response, callback)
  #       # Trigger completion callback
  #     end
  #
  #     def on_error(error, callback)
  #       # Trigger error callback
  #     end
  #
  #     def retry
  #       # Re-enqueue the job
  #     end
  #   end
  class TaskHandler
    # Triggers the completion callback with the response.
    #
    # @param response [Response] The HTTP response.
    # @param callback [String] The callback class name.
    # @return [void]
    def on_complete(response, callback)
      raise NotImplementedError, "#{self.class}#on_complete must be implemented"
    end

    # Triggers the error callback with the error.
    #
    # @param error [Error] The error.
    # @param callback [String] The callback class name.
    # @return [void]
    def on_error(error, callback)
      raise NotImplementedError, "#{self.class}#on_error must be implemented"
    end

    # Re-enqueues the original job for retry.
    #
    # The processor calls this method when a request can't be completed, such as
    # during processor shutdown, and must be retried later.
    #
    # @return [String] The new job ID.
    def retry
      raise NotImplementedError, "#{self.class}#retry must be implemented"
    end
  end
end
