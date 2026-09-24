# frozen_string_literal: true

module PatientHttp
  # The interface for observing request processing. Register an observer with a
  # {Processor} to receive events as requests are processed. Keep observers
  # lightweight. Limit them to work such as recording metrics.
  #
  # Each hook runs on the thread where its event originates:
  #
  # - `request_enqueued` and `request_rejected` run on the thread that calls
  #   {Processor#enqueue}, which is usually an application thread. They also run
  #   on the reactor thread for each task created to follow a redirect. For
  #   redirected requests, work in these hooks blocks the reactor and delays
  #   every other in-flight request.
  # - `capacity_exceeded` runs on the thread that calls {Processor#enqueue},
  #   which is usually an application thread.
  # - `request_start` runs on the reactor thread.
  # - `request_end`, `request_error`, and `completion_failed` run on a completion
  #   worker thread. `request_end` also runs on the reactor thread for followed
  #   redirects, and on the stopping thread for shutdown re-enqueues.
  # - `request_requeued` runs on the stopping thread or the reactor thread.
  # - `start` and `stop` run on the thread that calls {Processor#start} or
  #   {Processor#stop}.
  #
  # Observers must be thread-safe. Hooks are called from several threads. The
  # completion-time hooks run on any of the completion worker threads, so two of
  # them can run at the same time, in any order. Guard any counter or buffer
  # that an observer shares between calls. Setting `completion_threads` to 1
  # serializes the completion-time hooks, but not against hooks that run on
  # other threads.
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

    # Called when a request can't be enqueued because the processor is at capacity.
    #
    # @return [void]
    def capacity_exceeded
    end

    # Called when a request task is handed to the processor, before the task is
    # visible to the reactor.
    #
    # This notification always arrives before `request_start` for the task. You can
    # set up durable tracking, such as a crash recovery registry entry, with no
    # risk that the task completes first. If the processor doesn't accept the
    # task, `request_rejected` is sent afterward.
    #
    # Unlike other notifications, an error raised here propagates from
    # {Processor#enqueue} and rejects the task. If tracking setup fails, the task
    # isn't accepted as if it were durable.
    #
    # @param request_task [RequestTask] The request task that was enqueued.
    # @return [void]
    def request_enqueued(request_task)
    end

    # Called when the processor doesn't accept a request task that was announced
    # with `request_enqueued`, because the processor isn't running or is at
    # capacity. Remove anything you set up in `request_enqueued`. After this
    # notification, the caller owns the request again.
    #
    # @param request_task [RequestTask] The request task that was rejected.
    # @return [void]
    def request_rejected(request_task)
    end

    # Called when an incomplete request task is re-enqueued through its task
    # handler because the processor shut down or the reactor failed. After this
    # notification, the task handler's job system owns the request again, so remove
    # any durable tracking for the task.
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

    # Called when a finished result can't be delivered to the task handler after
    # all retries. `request_end` isn't sent for the task, so durable tracking set up
    # in `request_enqueued` stays in place. An external recovery process, such as an
    # orphan collector, can then re-enqueue the request.
    #
    # @param request_task [RequestTask] The request task whose result was not delivered.
    # @param error [StandardError] The delivery failure.
    # @return [void]
    def completion_failed(request_task, error)
    end
  end
end
