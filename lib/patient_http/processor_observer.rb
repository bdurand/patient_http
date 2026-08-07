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

    # Called when a request task is handed to the processor, before the task is
    # visible to the reactor. The notification is guaranteed to arrive before
    # request_start for the task, so observers can set up durable tracking
    # (e.g. a crash-recovery registry entry) with no risk that the task
    # completes first. If the processor does not accept the task,
    # request_rejected is sent afterward.
    #
    # @param request_task [RequestTask] the request task that was enqueued
    # @return [void]
    def request_enqueued(request_task)
    end

    # Called when a request task announced with request_enqueued was not
    # accepted by the processor (not running or at capacity). Observers should
    # tear down anything they set up in request_enqueued; the caller owns the
    # request again once this is sent.
    #
    # @param request_task [RequestTask] the request task that was rejected
    # @return [void]
    def request_rejected(request_task)
    end

    # Called when an incomplete request task was re-enqueued through its task
    # handler (processor shutdown or reactor failure). The task handler's job
    # system owns the request again once this is sent, so observers should
    # tear down any durable tracking for the task.
    #
    # @param request_task [RequestTask] the request task that was re-enqueued
    # @return [void]
    def request_requeued(request_task)
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
