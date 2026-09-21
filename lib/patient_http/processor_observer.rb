# frozen_string_literal: true

module PatientHttp
  # Interface for observing request processing.
  #
  # Register an observer with a {Processor} to receive events as the processor
  # processes requests. Keep an observer lightweight: do no work in it other than
  # recording metrics or something similar.
  #
  # The hooks run on different threads, depending on where the event starts:
  #
  # - `request_enqueued` and `request_rejected`: the thread that calls
  #   {Processor#enqueue}, which is usually an application thread, and the reactor
  #   thread for each task that is created to follow a redirect. Work in these hooks
  #   blocks the reactor for redirected requests, so keep it off the critical path, or
  #   accept the delay that it adds to every other in-flight request.
  # - `capacity_exceeded`: the thread that calls {Processor#enqueue}, which is usually
  #   an application thread.
  # - `request_start`: the reactor thread.
  # - `request_end`, `request_error`, and `completion_failed`: a completion worker
  #   thread. The `request_end` event also runs on the reactor thread for a redirect
  #   that the processor follows, and on the stopping thread for a shutdown
  #   re-enqueue.
  # - `request_requeued`: the stopping thread or the reactor thread.
  # - `start` and `stop`: the thread that calls {Processor#start} or
  #   {Processor#stop}.
  #
  # Observers must be thread-safe. The hooks run on several threads, and the
  # completion-time hooks run on any of the completion worker threads, so two of them
  # can run at the same time and in an order that does not match the order in which
  # the requests completed. Guard every counter or buffer that an observer shares
  # between calls. Setting `completion_threads` to 1 serializes the completion-time
  # hooks, but it does not serialize them against the hooks that run on other threads.
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

    # Called when a request cannot be enqueued because the processor is at maximum
    # capacity.
    #
    # @return [void]
    def capacity_exceeded
    end

    # Called when a request task is handed to the processor, before the task is
    # visible to the reactor.
    #
    # This notification always arrives before `request_start` for the task, so you can
    # set up durable tracking, for example a crash-recovery registry entry, with no
    # risk that the task completes first. If the processor does not accept the task,
    # `request_rejected` is sent afterwards. Unlike the other notifications, an error
    # that is raised here propagates from {Processor#enqueue} and rejects the task, so
    # a failed tracking setup does not let the task be accepted as if it were durable.
    #
    # @param request_task [RequestTask] The request task that was enqueued.
    # @return [void]
    def request_enqueued(request_task)
    end

    # Called when the processor did not accept a request task that was announced with
    # `request_enqueued`, because the processor is not running or is at maximum
    # capacity. Tear down anything that you set up in `request_enqueued`. The caller
    # owns the request again once this notification is sent.
    #
    # @param request_task [RequestTask] The request task that was rejected.
    # @return [void]
    def request_rejected(request_task)
    end

    # Called when an incomplete request task was re-enqueued through its task handler,
    # after a processor shutdown or a reactor failure. The job system of the task
    # handler owns the request again once this notification is sent, so tear down any
    # durable tracking for the task.
    #
    # @param request_task [RequestTask] The request task that was re-enqueued.
    # @return [void]
    def request_requeued(request_task)
    end

    # Called when a request starts processing.
    #
    # @param request_task [RequestTask] The request task that started.
    # @return [void]
    def request_start(request_task)
    end

    # Called when a request finishes processing.
    #
    # @param request_task [RequestTask] The request task that ended.
    # @return [void]
    def request_end(request_task)
    end

    # Called when a request encounters an error.
    #
    # @param error [StandardError] The error that occurred.
    # @return [void]
    def request_error(error)
    end

    # Called when a finished result could not be delivered to the task handler after
    # all the retries. The `request_end` event is not sent for the task, so the
    # durable tracking that was set up in `request_enqueued` stays in place, and an
    # external recovery process, such as an orphan collector, can re-enqueue the
    # request.
    #
    # @param request_task [RequestTask] The request task whose result was not
    #   delivered.
    # @param error [StandardError] The delivery failure.
    # @return [void]
    def completion_failed(request_task, error)
    end
  end
end
