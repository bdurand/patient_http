# frozen_string_literal: true

module PatientHttp
  # Interface for observing request processing. A process observer can be registered with
  # a Processor and receive events as requests are processed. Observers will run on the main
  # processor thread and so should be lightweight and not do processing other than recording
  # metrics or similar.
  class ProcessorObserver
    # Called when the processor starts.
    #
    # @return [void]
    def start
    end

    # Called when the processor stops.
    #
    # @return [void]
    def stop
    end

    # Called when a request cannot be enqueued because the processor is at capacity.
    #
    # @return [void]
    def capacity_exceeded
    end

    # Called when a request starts processing.
    #
    # @param request_task [RequestTask] the request task that started
    # @return [void]
    def request_start(request_task)
    end

    # Called when a request finishes processing.
    #
    # @param request_task [RequestTask] the request task that ended
    # @return [void]
    def request_end(request_task)
    end

    # Called when a request encounters an error.
    #
    # @param error [StandardError] the error that occurred
    # @return [void]
    def request_error(error)
    end
  end
end
