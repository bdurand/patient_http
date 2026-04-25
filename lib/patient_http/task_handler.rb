# frozen_string_literal: true

module PatientHttp
  # Abstract base class for handling task lifecycle operations.
  #
  # TaskHandler abstracts the job system integration, allowing RequestTask
  # to work with any job system without direct dependencies. Implementations
  # handle completion callbacks, error callbacks, and job retry operations.
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
    # Trigger the completion callback with the response.
    #
    # @param response [Response] the HTTP response object
    # @param callback [String] callback class name
    # @return [void]
    def on_complete(response, callback)
      raise NotImplementedError, "#{self.class}#on_complete must be implemented"
    end

    # Trigger the error callback with the error.
    #
    # @param error [Error] the error object
    # @param callback [String] callback class name
    # @return [void]
    def on_error(error, callback)
      raise NotImplementedError, "#{self.class}#on_error must be implemented"
    end

    # Re-enqueue the original job for retry.
    #
    # Called when a request cannot be completed (e.g., processor shutdown)
    # and needs to be retried later.
    #
    # @return [String] the new job ID
    def retry
      raise NotImplementedError, "#{self.class}#retry must be implemented"
    end
  end
end
