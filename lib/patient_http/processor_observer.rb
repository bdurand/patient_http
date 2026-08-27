# frozen_string_literal: true

module PatientHttp
  # Interface for observing request processing. A process observer can be registered with
  # a Processor and receive events as requests are processed. Observers should be
  # lightweight and not do processing other than recording metrics or similar.
  #
  # Hooks run on different threads depending on where the event originates:
  # - request_enqueued, request_rejected: the thread calling Processor#enqueue
  #   (usually an application thread), and the reactor thread for each task
  #   created to follow a redirect. Work done in these hooks blocks the reactor
  #   for redirected requests, so keep it off the critical path or accept the
  #   delay it adds to every other in-flight request
  # - capacity_exceeded: the thread calling Processor#enqueue (usually an
  #   application thread)
  # - request_start: the reactor thread
  # - request_end, request_error, completion_failed: a completion worker
  #   thread (request_end also fires on the reactor thread for followed
  #   redirects, and on the stopping thread for shutdown re-enqueues)
  # - request_requeued: the stopping thread or the reactor thread
  # - start, stop: the thread calling Processor#start / Processor#stop
  #
  # Observers must be thread-safe. Hooks are called from several threads, and
  # the completion-time hooks run on any of the completion worker threads, so
  # two of them can run at the same time and in an order unrelated to the
  # order the requests completed. Guard any counter or buffer an observer
  # shares between calls. Setting completion_threads to 1 serializes the
  # completion-time hooks but does not serialize them against the hooks that
  # fire on other threads.
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
    # request_rejected is sent afterward. Unlike other notifications, an error
    # raised here propagates from Processor#enqueue and rejects the task, so a
    # failed tracking setup does not let the task be accepted as if it were
    # durable.
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

    # Called when a finished result could not be delivered to the task handler
    # after all retries. request_end is NOT sent for the task, so durable
    # tracking set up in request_enqueued stays in place and an external
    # recovery process (e.g. an orphan collector) can re-enqueue the request.
    #
    # @param request_task [RequestTask] the request task whose result was not delivered
    # @param error [StandardError] the delivery failure
    # @return [void]
    def completion_failed(request_task, error)
    end
  end
end
