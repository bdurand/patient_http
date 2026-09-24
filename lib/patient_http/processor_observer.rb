# frozen_string_literal: true

module PatientHttp
  # The base class for objects that receive processor events. Register an
  # observer with {Processor#observe}. Subclass it and override the methods for
  # the events that you need.
  #
  # Keep observers lightweight. Use them to record metrics or to track
  # requests, not to do other work.
  #
  # Each method runs on the thread where its event occurs:
  #
  # - {#request_enqueued} and {#request_rejected}: The thread that calls
  #   {Processor#enqueue}, usually an application thread. For a redirect, the
  #   reactor thread. Slow work in these methods delays every in-flight request
  #   when a redirect is followed.
  # - {#capacity_exceeded}: The thread that calls {Processor#enqueue}.
  # - {#request_start}: The reactor thread.
  # - {#request_end}, {#request_error}, and {#completion_failed}: A completion
  #   worker thread. {#request_end} also runs on the reactor thread for a
  #   followed redirect, and on the stopping thread for a request that's
  #   re-enqueued at shutdown.
  # - {#request_requeued}: The stopping thread or the reactor thread.
  # - {#start} and {#stop}: The thread that calls {Processor#start} or
  #   {Processor#stop}.
  #
  # Observers must be thread-safe. Methods run on several threads, and two
  # completion worker threads can call methods at the same time, in any order.
  # Protect any counter or buffer that calls share. If `completion_threads` is
  # 1, the completion worker calls run one at a time, but they can still run at
  # the same time as calls on other threads.
  class ProcessorObserver
    # Runs when the processor starts.
    #
    # @return [void]
    def start
    end

    # Runs when the processor stops.
    #
    # @return [void]
    def stop
    end

    # Runs when a request can't be enqueued because the processor is at
    # `max_connections`.
    #
    # @return [void]
    def capacity_exceeded
    end

    # Runs when a task is given to the processor, before the reactor can see
    # the task.
    #
    # This method always runs before {#request_start} for the task. As a
    # result, an observer can set up durable tracking, such as a crash-recovery
    # registry entry, before the task can finish. If the processor doesn't
    # accept the task, {#request_rejected} runs next.
    #
    # Unlike the other methods, an error raised here isn't caught.
    # {Processor#enqueue} raises the error and rejects the task. As a result,
    # the processor never accepts a task whose tracking failed.
    #
    # @param request_task [RequestTask] The task.
    # @return [void]
    def request_enqueued(request_task)
    end

    # Runs when the processor doesn't accept a task after {#request_enqueued},
    # because the processor isn't running or is at capacity. Remove anything
    # that {#request_enqueued} set up. After this call, the caller owns the
    # request again.
    #
    # @param request_task [RequestTask] The task.
    # @return [void]
    def request_rejected(request_task)
    end

    # Runs when a task that didn't finish is re-enqueued through its task
    # handler, because the processor stopped or the reactor failed. After this
    # call, the job system owns the request again, so remove any durable
    # tracking for the task.
    #
    # @param request_task [RequestTask] The task.
    # @return [void]
    def request_requeued(request_task)
    end

    # Runs when a request starts.
    #
    # @param request_task [RequestTask] The task.
    # @return [void]
    def request_start(request_task)
    end

    # Runs when a request finishes and its result is delivered.
    #
    # @param request_task [RequestTask] The task.
    # @return [void]
    def request_end(request_task)
    end

    # Runs when a request fails with an error.
    #
    # @param error [StandardError] The error.
    # @return [void]
    def request_error(error)
    end

    # Runs when the task handler can't take a result after all retries.
    #
    # {#request_end} doesn't run for the task. As a result, durable tracking
    # from {#request_enqueued} stays in place, and a recovery process, such as
    # an orphan collector, can re-enqueue the request.
    #
    # @param request_task [RequestTask] The task.
    # @param error [StandardError] The error from the last delivery attempt.
    # @return [void]
    def completion_failed(request_task, error)
    end
  end
end
