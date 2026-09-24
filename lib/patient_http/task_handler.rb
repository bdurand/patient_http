# frozen_string_literal: true

module PatientHttp
  # The abstract base class that connects a {RequestTask} to a job system.
  #
  # The processor calls the task handler to deliver a result and to re-enqueue
  # a request that didn't finish. Because of this class, {RequestTask} doesn't
  # depend on a job system.
  #
  # The processor calls {#on_complete} and {#on_error} on its completion worker
  # threads. The methods must be thread-safe and idempotent, and they should
  # return quickly, for example after they enqueue a job.
  #
  # @abstract Subclass it and implement all methods.
  #
  # @example Create a task handler
  #   class MyTaskHandler < PatientHttp::TaskHandler
  #     def on_complete(response, callback)
  #       MyJobSystem.enqueue(callback, :on_complete, response.as_json)
  #     end
  #
  #     def on_error(error, callback)
  #       MyJobSystem.enqueue(callback, :on_error, error.as_json)
  #     end
  #
  #     def retry
  #       MyJobSystem.enqueue_job(@job_id)
  #     end
  #   end
  class TaskHandler
    # Delivers a response to the callback service's `on_complete` method.
    #
    # @param response [Response] The HTTP response.
    # @param callback [String] The callback service class name.
    # @return [void]
    def on_complete(response, callback)
      raise NotImplementedError, "#{self.class}#on_complete must be implemented"
    end

    # Delivers an error to the callback service's `on_error` method.
    #
    # @param error [Error] The error.
    # @param callback [String] The callback service class name.
    # @return [void]
    def on_error(error, callback)
      raise NotImplementedError, "#{self.class}#on_error must be implemented"
    end

    # Re-enqueues the original job, so the request runs again later.
    #
    # The processor calls this method for a request that didn't finish, for
    # example when the processor shuts down.
    #
    # @return [String] The new job ID.
    def retry
      raise NotImplementedError, "#{self.class}#retry must be implemented"
    end
  end
end
