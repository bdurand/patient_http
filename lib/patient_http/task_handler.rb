# frozen_string_literal: true

module PatientHttp
  # Abstract base class that handles the task lifecycle operations.
  #
  # A TaskHandler holds the integration with the job system, so that a {RequestTask}
  # works with any job system and depends on none of them directly. An implementation
  # handles the completion callbacks, the error callbacks, and the job retries.
  #
  # @abstract Subclass this class and implement every method to create a handler.
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
    # Runs the completion callback with the response.
    #
    # @param response [Response] The HTTP response.
    # @param callback [String] The callback class name.
    # @return [void]
    def on_complete(response, callback)
      raise NotImplementedError, "#{self.class}#on_complete must be implemented"
    end

    # Runs the error callback with the error.
    #
    # @param error [Error] The error.
    # @param callback [String] The callback class name.
    # @return [void]
    def on_error(error, callback)
      raise NotImplementedError, "#{self.class}#on_error must be implemented"
    end

    # Re-enqueues the original job for a retry.
    #
    # This method runs when a request cannot be completed, for example during a
    # processor shutdown, and must be retried later.
    #
    # @return [String] The new job ID.
    def retry
      raise NotImplementedError, "#{self.class}#retry must be implemented"
    end
  end
end
