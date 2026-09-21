# frozen_string_literal: true

module PatientHttp
  # Core processor that runs async HTTP requests in a dedicated thread.
  class Processor
    include TimeHelper
    include RedirectHelper

    # Seconds to wait for a request when the reactor loop reads from the queue.
    DEQUEUE_TIMEOUT = 1.0

    # Base delay, in seconds, between attempts when the delivery of a completed result
    # fails. The delay grows linearly with each attempt.
    COMPLETION_RETRY_DELAY = 0.5

    # Seconds that the completion executor has to drain during a shutdown. The
    # teardown of the reactor and {#stop} share this budget, so the reactor can never
    # spend more time draining than {#stop} waits for it.
    COMPLETION_SHUTDOWN_TIMEOUT = 5

    # @return [Configuration] The configuration of the processor.
    attr_reader :config

    # @return [String] The name of the processor. The name is part of the thread
    #   names, so that you can tell several named processors in one process apart.
    attr_reader :name

    # The callback that runs after each request. It is available only in testing mode.
    #
    # @api private
    attr_accessor :testing_callback

    # Initializes a new Processor.
    #
    # @param config [Configuration] The configuration.
    # @param name [String, Symbol] An optional name that identifies this processor
    #   when a process runs more than one.
    # @return [void]
    def initialize(config, name: "default")
      @config = config
      @name = name.to_s
      @lifecycle = LifecycleManager.new
      @queue = Thread::Queue.new
      @reactor_thread = nil
      # Serializes start/stop so a start cannot interleave with a stop that is
      # still reaping its reactor thread (and vice versa).
      @lifecycle_mutex = Mutex.new
      # Incremented once per reactor run; lets a reactor's teardown detect
      # whether it is still the current run before mutating shared state.
      @reactor_generation = 0
      @inflight_requests = Concurrent::Hash.new
      @pending_tasks = Concurrent::Hash.new
      # Tasks pushed onto @queue but not yet popped by the reactor. Kept in a
      # hash because Thread::Queue cannot be enumerated; used to report all
      # tracked task ids, for example for heartbeat updates on queued tasks.
      @queued_tasks = Concurrent::Hash.new
      @tasks_lock = Mutex.new
      @idle_condition = ConditionVariable.new
      @testing_callback = nil
      @http_client = Client.new(self)
      @observers = []
      @completion_executor = nil
    end

    # Starts the processor.
    #
    # @return [void]
    def start
      observers_to_notify = nil

      # Hold the lifecycle mutex across the whole start so a concurrent stop
      # cannot interleave with (and reap) the reactor thread we are creating.
      @lifecycle_mutex.synchronize do
        # Claim this reactor run's generation atomically with the state
        # transition. The reactor thread captures it below and its teardown
        # only mutates shared state while it is still the current generation.
        generation = @tasks_lock.synchronize do
          return unless @lifecycle.start!
          @reactor_generation += 1
        end

        # The completion executor delivers finished results on its own worker
        # threads so the reactor thread never blocks on response decoding,
        # serialization, or callback delivery. A new executor is created for
        # each run, like the reactor thread.
        executor = CompletionExecutor.new(
          threads: @config.completion_threads,
          logger: @config.logger,
          thread_name_prefix: thread_name("patient-http-completion"),
          on_finished: -> { signal_idle }
        )
        @tasks_lock.synchronize { @completion_executor = executor }

        @reactor_thread = Thread.new do
          Thread.current.name = thread_name("patient-http-processor")
          run_reactor
        rescue => e
          @config.logger&.error("[PatientHttp] Processor error: #{e.message}\n#{e.backtrace.join("\n")}")

          raise if PatientHttp.testing?
        ensure
          # Mark the processor stopped when the reactor exits and re-enqueue any
          # tasks still being tracked, so a reactor that exits without a stop()
          # call, for example after an unhandled error, does not lose in-flight or pending
          # requests or leak stale tracking entries into a later run.
          #
          # Only act while this is still the current generation: a newer start
          # (after a stop) owns the processor state and a stale reactor from a
          # prior run must not clobber it. Snapshot and clear happen under the
          # lock; re-enqueueing runs outside it. This is idempotent with stop()'s
          # reenqueue_pending_requests: whichever runs second snapshots an empty
          # set.
          current_generation = @tasks_lock.synchronize { @reactor_generation == generation }
          if current_generation
            begin
              # Drain the completion executor before stealing tracked tasks so
              # results already handed off are delivered rather than retried.
              # Tasks whose completion job never ran stay in in-flight tracking
              # and are re-enqueued below. The drain is bounded so it cannot
              # outlast stop()'s own shutdown budget, and it runs in its own
              # block so the re-enqueue still happens if a stop() that gave up
              # waiting kills this thread mid-drain.
              executor.shutdown(timeout: COMPLETION_SHUTDOWN_TIMEOUT)
            ensure
              orphaned_tasks = @tasks_lock.synchronize do
                if @reactor_generation == generation
                  drain_tracked_tasks_locked
                else
                  []
                end
              end
              reenqueue_tasks(orphaned_tasks)
              # Hand back tasks still sitting in the queue as well; a reactor
              # that exits without a stop() call is the last owner of those
              # tasks. stop() performs the same drain after reaping the
              # reactor, and whichever drain runs second finds nothing left.
              reenqueue_remaining_queue_items
            end
          end
        end

        # The transition can fail if the reactor thread already failed and
        # marked the processor stopped. Capture the observer snapshot under the
        # same lock as the transition so an observer registered concurrently via
        # #observe is notified of start by exactly one path (here or in #observe).
        started, observers = @tasks_lock.synchronize do
          [@lifecycle.running!, @observers.dup]
        end
        observers_to_notify = observers if started

        # Block until the reactor is ready
        @lifecycle.wait_for_reactor(timeout: 5)
      end

      # Notify observers outside the lifecycle mutex so an observer callback
      # that re-enters the processor cannot deadlock.
      observers_to_notify&.each { |observer| notify_observer(observer) { |o| o.start } }
    end

    # Stops the processor.
    #
    # @param timeout [Numeric, nil] How long to wait for in-flight requests, in
    #   seconds.
    # @return [void]
    def stop(timeout: nil)
      timeout ||= @config.shutdown_timeout
      should_notify_stop = false

      # Hold the lifecycle mutex across the whole stop so a concurrent start
      # cannot begin (and reassign @reactor_thread) while we are tearing down.
      @lifecycle_mutex.synchronize do
        # Atomically transition to stopping and capture the reactor thread for
        # this run. Joining/killing the captured reference rather than the ivar
        # means we can never tear down a reactor from a different run.
        reactor = @tasks_lock.synchronize do
          return unless @lifecycle.stop!
          @reactor_thread
        end

        # Interrupt the reactor's queue wait by pushing a sentinel value
        @queue.push(nil)

        # Wait for in-flight and pending requests to complete, including
        # results still being delivered by the completion executor.
        # Queue items are not checked here — they will be re-enqueued by
        # reenqueue_remaining_queue_items after the reactor thread exits.
        if timeout > 0
          deadline = monotonic_time + timeout
          @tasks_lock.synchronize do
            loop do
              break if @pending_tasks.empty? && @inflight_requests.empty? && completion_executor_settled?
              remaining = deadline - monotonic_time
              break if remaining <= 0
              @idle_condition.wait(@tasks_lock, remaining)
            end
          end
        end

        reenqueue_pending_requests

        # Reap the reactor thread — unless stop was called from the reactor
        # thread itself, for example from a task callback or observer, where joining
        # the current thread would raise ThreadError. In that case the reactor
        # exits on its own once the callback returns (its loop sees the stopped
        # state) and its ensure block performs the same cleanup.
        if reactor && !reactor.equal?(Thread.current)
          # The join stays short: the reactor's teardown drains the completion
          # executor, which can join this very thread when stop was called from
          # a completion callback. Killing the reactor breaks that standoff and
          # its teardown still re-enqueues from an ensure block.
          reactor.join(1) if reactor.alive?
          if reactor.alive?
            reactor.kill
            # Wait for the killed thread's ensure blocks so a stale lifecycle
            # transition cannot fire during a subsequent start.
            reactor.join(1)
          end
        end
        @tasks_lock.synchronize do
          @reactor_thread = nil if @reactor_thread.equal?(reactor)
        end

        # Shut down the completion executor. The reactor's own teardown
        # normally drains it already; this pass reaps any worker that is still
        # stuck past the deadline. Remaining queued jobs belong to tasks that
        # were re-enqueued above, so they no-op when their claim fails.
        @completion_executor&.shutdown(timeout: COMPLETION_SHUTDOWN_TIMEOUT)

        # Run a second pass now that the reactor has exited to catch any task
        # that slipped into pending/in-flight tracking after the first snapshot
        # (a task can be popped from the queue but not yet tracked when the
        # snapshot is taken).
        reenqueue_pending_requests

        # Drain any items left in the queue after the reactor has exited.
        # This must happen after the reactor thread is done to avoid consuming
        # the nil sentinel that wakes the reactor.
        reenqueue_remaining_queue_items

        should_notify_stop = true
      end

      # Notify observers outside the lifecycle mutex so an observer callback
      # that re-enters the processor cannot deadlock.
      notify_observers { |observer| observer.stop } if should_notify_stop
    end

    # Drains the processor, which stops it from accepting new requests.
    #
    # @return [void]
    def drain
      @tasks_lock.synchronize do
        return unless @lifecycle.drain!
      end

      @config.logger&.info("[PatientHttp] Processor draining (no longer accepting new requests)")
    end

    # Enqueues a request task for processing.
    #
    # @param task [RequestTask] The request task to enqueue.
    # @return [void]
    # @raise [NotRunningError] If the processor is not running.
    # @raise [MaxCapacityError] If the processor is at maximum capacity.
    def enqueue(task)
      raise NotRunningError.new("Cannot enqueue request: processor is #{state}") unless running?

      accepted = announce_and_enqueue(task) do
        # The pre-check above is advisory; re-check the running state under
        # the lock since observers were notified outside of it.
        raise NotRunningError.new("Cannot enqueue request: processor is #{state}") unless running?

        # Check capacity - the task is only accepted below max connections.
        @queue.size + @pending_tasks.size + @inflight_requests.size < @config.max_connections
      end

      unless accepted
        notify_observers { |observer| observer.capacity_exceeded }
        raise MaxCapacityError.new("Cannot enqueue request: already at max capacity (#{@config.max_connections} connections)")
      end
    end

    # Returns the current state of the processor.
    #
    # @return [Symbol] The current state.
    def state
      @lifecycle.state
    end

    # Checks whether the processor is starting.
    #
    # @return [Boolean] Whether the processor is starting.
    def starting?
      @lifecycle.starting?
    end

    # Checks whether the processor is running.
    #
    # @return [Boolean] Whether the processor is running.
    def running?
      @lifecycle.running?
    end

    # Checks whether the processor is stopped.
    #
    # @return [Boolean] Whether the processor is stopped.
    def stopped?
      @lifecycle.stopped?
    end

    # Checks whether the processor is draining.
    #
    # @return [Boolean] Whether the processor is draining.
    def draining?
      @lifecycle.draining?
    end

    # Checks whether the processor is drained, that is, draining and idle.
    #
    # @return [Boolean] Whether the processor is drained.
    def drained?
      @lifecycle.draining? && idle?
    end

    # Checks whether the processor is stopping.
    #
    # @return [Boolean] Whether the processor is stopping.
    def stopping?
      @lifecycle.stopping?
    end

    # Checks whether the processor is idle, that is, whether it has no queued or
    # in-flight requests and no results that the completion executor is still
    # delivering.
    #
    # @return [Boolean] Whether the processor is idle.
    def idle?
      executor = @completion_executor
      tracking_empty = @tasks_lock.synchronize do
        @queue.empty? && @pending_tasks.empty? && @inflight_requests.empty?
      end

      tracking_empty && (executor.nil? || executor.idle?)
    end

    # Returns how many more requests the processor can accept before it reaches
    # maximum capacity.
    #
    # This value is advisory. The authoritative check happens inside {#enqueue}, so a
    # concurrent enqueue can still raise {MaxCapacityError}. This method notifies no
    # observers and registers nothing durably, so it is cheap to call before you pay
    # the cost of an enqueue.
    #
    # @return [Integer] The remaining capacity, which is never negative.
    def remaining_capacity
      @tasks_lock.synchronize do
        remaining = @config.max_connections - (@queue.size + @pending_tasks.size + @inflight_requests.size)
        (remaining > 0) ? remaining : 0
      end
    end

    # Checks whether the processor can accept at least one more request. This value is
    # advisory. For more information, see {#remaining_capacity}.
    #
    # @return [Boolean] Whether capacity is available.
    def capacity_available?
      remaining_capacity > 0
    end

    # Returns the number of in-flight requests, that is, the HTTP calls that are
    # running.
    #
    # This count does not include queued or pending tasks. For the total pipeline
    # count that the capacity check uses, see {#total_count}.
    #
    # @return [Integer] The number of in-flight requests.
    def inflight_count
      @inflight_requests.size
    end

    # Returns the total number of tasks in the pipeline: queued, pending, and
    # in-flight.
    #
    # {#enqueue} uses this count to enforce the capacity limit.
    #
    # @return [Integer] The number of tasks in the pipeline.
    def total_count
      @tasks_lock.synchronize do
        @queue.size + @pending_tasks.size + @inflight_requests.size
      end
    end

    # Returns the IDs of the in-flight requests.
    #
    # @return [Array<String>] The in-flight request IDs.
    def inflight_request_ids
      @tasks_lock.synchronize do
        @inflight_requests.keys
      end
    end

    # Returns the IDs of all tasks in the pipeline: queued, pending, and in-flight.
    #
    # Use this method to keep durable tracking, such as heartbeats, alive for tasks
    # that the processor accepted but has not started yet.
    #
    # @return [Array<String>] The tracked request IDs.
    def tracked_request_ids
      @tasks_lock.synchronize do
        (@queued_tasks.keys + @pending_tasks.keys + @inflight_requests.keys).uniq
      end
    end

    # Adds an observer for processor events.
    #
    # @param observer [ProcessorObserver] The observer to add.
    # @return [void]
    # @raise [ArgumentError] If the observer is already added.
    def observe(observer)
      notify_start = false

      @tasks_lock.synchronize do
        raise ArgumentError.new("Observer already added") if @observers.include?(observer)

        @observers << observer
        # Only self-notify when already running. An observer added while the
        # processor is still starting is picked up by start's atomic observer
        # snapshot, so notifying here too would deliver start twice.
        notify_start = running?
      end

      notify_observer(observer) { |o| o.start } if notify_start
    end

    # Waits for the processor to start.
    #
    # @param timeout [Numeric] The maximum time to wait, in seconds.
    # @return [Boolean] Whether the processor started. False means that the timeout
    #   was reached.
    # @api private
    def wait_for_running(timeout: 5)
      start
      @lifecycle.wait_for_running(timeout: timeout)
    end

    # Waits for the queue to become empty and for all in-flight requests to complete.
    # Use this method in tests.
    #
    # @param timeout [Numeric] The maximum time to wait, in seconds.
    # @return [Boolean] Whether the processing completed. False means that the timeout
    #   was reached.
    # @api private
    def wait_for_idle(timeout: 1)
      @lifecycle.wait_for_condition(timeout: timeout) { idle? }
    end

    # Waits for at least one request to start processing. Use this method in tests.
    #
    # @param timeout [Numeric] The maximum time to wait, in seconds.
    # @return [Boolean] Whether a request started processing. False means that the
    #   timeout was reached.
    # @api private
    def wait_for_processing(timeout: 1)
      @lifecycle.wait_for_condition(timeout: timeout) do
        !@inflight_requests.empty? || !@pending_tasks.empty?
      end
    end

    # Runs the processor for the duration of a block. Use this method in tests to make
    # sure that the processor is started and stopped correctly.
    #
    # @yield A block that runs while the processor is running.
    # @return [void]
    # @api private
    def run
      start
      wait_for_running
      yield
    ensure
      stop(timeout: 0)
      wait_for_idle
    end

    private

    # Builds a thread name for this processor. The default processor keeps the bare
    # prefix. A named processor appends its name, so that you can tell several
    # processors in one process apart.
    #
    # @param prefix [String] The base thread name.
    # @return [String] The thread name.
    def thread_name(prefix)
      (@name == "default") ? prefix : "#{prefix}-#{@name}"
    end

    # Runs the async reactor loop.
    #
    # @return [void]
    def run_reactor
      Async do |task|
        # Signal that the reactor is ready
        @lifecycle.reactor_ready!

        @config.logger&.info("[PatientHttp] Processor started")

        # Main loop: monitor shutdown/drain and process requests
        loop do
          break if stopping? || stopped?

          # Pop request task from queue with timeout to periodically check shutdown
          request_task = dequeue_request(timeout: DEQUEUE_TIMEOUT)
          next unless request_task

          # Track as pending immediately to avoid race condition with stop()
          @tasks_lock.synchronize do
            @queued_tasks.delete(request_task.id)
            @pending_tasks[request_task.id] = request_task
          end

          # If we've dequeued a task, we must process it even if stopping
          # to avoid losing the request (shutdown will handle re-enqueuing if incomplete)

          # Spawn a new fiber to process this request task
          task.async do
            process_request(request_task)
          rescue => e
            @config.logger&.error("[PatientHttp] Error processing request: #{e.inspect}\n#{e.backtrace.join("\n")}")

            warn(e.inspect, e.backtrace) if PatientHttp.testing?
          end
        end

        # Wait for in-flight request fibers to finish so responses that
        # complete during the graceful shutdown window are delivered before
        # the connection pools are closed below. Transient tasks (such as the
        # connection pools' gardener tasks) are excluded; they are shut down
        # by closing the HTTP client.
        loop do
          children = task.children&.to_a&.reject(&:transient?)
          break if children.nil? || children.empty?

          children.each do |child|
            child.wait
          rescue => e
            @config.logger&.error("[PatientHttp] Error waiting for in-flight request: #{e.inspect}")
          end
        end

        @config.logger&.info("[PatientHttp] Processor stopped")
      rescue Async::Stop
        @config.logger&.info("[PatientHttp] Reactor received stop signal")
      rescue => e
        @config.logger&.error("[PatientHttp] Reactor loop error: #{e.inspect}\n#{e.backtrace.join("\n")}")
      ensure
        # Close the HTTP connection pools while still inside the reactor so the
        # pools shut down in an orderly fashion: in-flight responses have been
        # delivered above, and each pool's background gardener task is stopped
        # by the pool itself rather than force-cancelled by the dying reactor.
        #
        # Note: on Ruby < 3.2.7 / < 3.3.7, stopping a gardener still logs a
        # spurious (harmless) ThreadError: "Attempt to unlock a mutex which is
        # not locked" — a fiber interrupted in ConditionVariable#wait fails to
        # re-acquire its mutex (https://bugs.ruby-lang.org/issues/20907, fixed
        # in Ruby 3.2.7+, 3.3.7+, and 3.4+).
        begin
          @http_client.close
        rescue => e
          @config.logger&.error("[PatientHttp] Error closing HTTP client: #{e.inspect}")
        end
      end
    end

    # Reads a request task from the queue, with a timeout.
    #
    # @param timeout [Numeric] The timeout, in seconds.
    # @return [RequestTask, nil] The request task, or nil if the timeout was reached.
    def dequeue_request(timeout:)
      @queue.pop(timeout: timeout)
    rescue ThreadError
      # Queue is empty and timeout expired
      nil
    end

    # Processes a single HTTP request task.
    #
    # @param task [RequestTask] The request task to process.
    # @return [void]
    def process_request(task)
      # Move from pending to in-flight tracking. If the shutdown deadline has
      # already passed, the shutdown sequence re-enqueues the task, so leave
      # it in pending tracking and don't execute it.
      @tasks_lock.synchronize do
        return if stopped?

        @pending_tasks.delete(task.id)
        @inflight_requests[task.id] = task
        # Mark the task started in the same locked section that tracks it so
        # a shutdown snapshot always sees a consistent started state. The
        # shutdown re-enqueue path uses started? to pair request_end with
        # request_start.
        task.started!
      end

      notify_observers { |observer| observer.request_start(task) }

      begin
        response_data = @http_client.make_request(task.request, task.id)

        # If the shutdown deadline passed while the request was in flight, the
        # shutdown sequence has re-enqueued the task; discard the response.
        return if stopped?

        if should_follow_redirect?(task, response_data)
          handle_redirect(task, response_data)
        else
          # Hand the result to the completion executor without claiming the
          # task. The task stays in in-flight tracking until a completion
          # worker claims it, so the shutdown re-enqueue protocol covers
          # results that are queued but not yet delivered.
          dispatch_completion(task, response_data: response_data)
        end
      rescue ResponseReader::ReadAbortedError
        # The processor stopped past its shutdown deadline while the response
        # body was being read. The shutdown sequence re-enqueues the task, so
        # there is nothing to deliver.
        nil
      rescue => e
        dispatch_completion(task, error: e)
      end
    end

    # Hands a finished HTTP exchange to the completion executor.
    #
    # @param task [RequestTask] The request task.
    # @param response_data [Hash, nil] The raw response data, on success.
    # @param error [Exception, nil] The error, on failure.
    # @return [void]
    def dispatch_completion(task, response_data: nil, error: nil)
      executor = @completion_executor
      executor.enqueue(-> { run_completion(task, response_data: response_data, error: error) })
    rescue ClosedQueueError
      # The executor is already shut down. The task is still tracked, so the
      # shutdown sequence re-enqueues it.
      nil
    end

    # Delivers a finished result on a completion worker thread. This method decodes
    # the response, claims the task, runs the result callbacks, and notifies the
    # observers.
    #
    # When the delivery fails after all the retries, the `request_end` event is not
    # sent. Durable tracking, such as a crash-recovery record, therefore stays in
    # place, and the request can be recovered instead of being lost.
    #
    # @param task [RequestTask] The request task.
    # @param response_data [Hash, nil] The raw response data, on success.
    # @param error [Exception, nil] The error, on failure.
    # @return [void]
    def run_completion(task, response_data: nil, error: nil)
      response = nil

      if error.nil?
        begin
          response = task.build_response(**@http_client.decode_response(response_data))
          if task.raise_error_responses && !response.success?
            error = HttpError.new(response)
          end
        rescue => e
          error = e
        end
      end

      # A claim failure means the shutdown sequence already re-enqueued the
      # task; the result must not be delivered.
      return unless claim_task(task)

      failure = nil
      begin
        if error
          notify_observers { |observer| observer.request_error(error) }
          failure = handle_error(task, error)
        else
          failure = handle_completion(task, response)
        end

        if failure.nil?
          finish_task(task)
        else
          notify_observers { |observer| observer.completion_failed(task, failure) }
        end
      ensure
        @testing_callback&.call(task) if PatientHttp.testing?
      end

      raise failure if failure && PatientHttp.testing?
    end

    # Runs a delivery block with a limited number of retries. The retries back off
    # linearly. Sleeping is safe here, because the delivery runs on a completion
    # worker thread and not on the reactor thread.
    #
    # The block calls the task handler, so a retry calls the handler again. A handler
    # that raises an error after its side effect therefore repeats that side effect.
    # Handlers must be idempotent, or `completion_retries` must be set to 0.
    #
    # @param task [RequestTask] The request task, used for log context.
    # @yield The delivery block to run.
    # @return [Exception, nil] The final failure, or nil on success.
    def deliver_with_retries(task)
      attempts = 0

      begin
        yield
        nil
      rescue => e
        attempts += 1
        if attempts <= @config.completion_retries
          @config.logger&.warn(
            "[PatientHttp] Retrying result delivery for request #{task.id} " \
            "(attempt #{attempts + 1}): #{e.class} - #{e.message}"
          )
          sleep(COMPLETION_RETRY_DELAY * attempts) unless PatientHttp.testing?
          retry
        end
        e
      end
    end

    # Takes ownership of the delivery of the result of a task by removing the task
    # from in-flight tracking. The operation is atomic.
    #
    # This method returns false when the shutdown sequence already claimed the task
    # and re-enqueued it for a retry. In that case, the result must not be delivered.
    #
    # @param task [RequestTask] The request task.
    # @return [Boolean] Whether this caller owns the delivery of the result.
    def claim_task(task)
      @tasks_lock.synchronize do
        !@inflight_requests.delete(task.id).nil?
      end
    end

    # Signals the idle waiters and notifies the observers after a claimed task
    # finishes.
    #
    # @param task [RequestTask] The request task.
    # @return [void]
    def finish_task(task)
      signal_idle
      notify_observers { |observer| observer.request_end(task) }
    end

    # Broadcasts the idle condition when the pipeline is empty. This method runs after
    # a claimed task finishes, and it runs in the completion executor after each job,
    # so that the threads that wait in {#stop} wake up once the last delivery
    # completes.
    #
    # @return [void]
    def signal_idle
      executor = @completion_executor
      @tasks_lock.synchronize do
        if @pending_tasks.empty? && @inflight_requests.empty? && (executor.nil? || executor.idle?)
          @idle_condition.broadcast
        end
      end
    end

    # Checks whether {#stop} must keep waiting for the completion executor.
    #
    # When {#stop} is called from a completion worker itself, through a result
    # callback, the job of that worker never settles. The job is therefore treated as
    # settled, so that the processor does not wait for the full timeout.
    #
    # @return [Boolean] Whether the completion executor has settled.
    def completion_executor_settled?
      executor = @completion_executor
      executor.nil? || executor.worker_thread? || executor.idle?
    end

    # Handles a successful response. The caller must have claimed the task with
    # {#claim_task}, so that the result is delivered exactly once.
    #
    # @param task [RequestTask] The request task.
    # @param response [Response] The response.
    # @return [Exception, nil] The delivery failure, or nil on success.
    def handle_completion(task, response)
      failure = deliver_with_retries(task) { task.completed!(response) }

      if failure
        @config.logger&.error(
          "[PatientHttp] Failed to enqueue completion callback for request #{task.id}: " \
          "#{failure.class} - #{failure.message}"
        )
      else
        @config.logger&.debug(
          "[PatientHttp] Request #{task.id} succeeded with status #{response.status}, " \
          "enqueued callback #{task.callback}"
        )
      end

      failure
    end

    # Handles a redirect response on the reactor thread.
    #
    # Redirect errors go to the completion executor for delivery. When the processor
    # follows a redirect, it removes the original task from in-flight tracking and
    # pushes the redirect task onto the queue in a single locked section, so that a
    # concurrent call to {#idle?} never sees a moment when neither task is tracked.
    #
    # @param task [RequestTask] The request task.
    # @param response_data [Hash] The response data, with the status, headers, and
    #   body.
    # @return [void]
    def handle_redirect(task, response_data)
      status = response_data[:status]
      location = response_data[:headers]["location"]

      # Check for redirect errors
      error = check_redirect_error(task, response_data)
      if error
        dispatch_completion(task, error: error)
        return
      end

      # Create the redirect task, then atomically claim the original (remove it
      # from in-flight) and enqueue the redirect. If the claim fails the
      # shutdown sequence already re-enqueued the original, so drop the redirect.
      redirect_task = build_redirect_task(task, response_data)

      begin
        claimed = announce_and_enqueue(redirect_task) do
          !@inflight_requests.delete(task.id).nil?
        end
      rescue => e
        # The redirect could not be registered, for example because the durable
        # tracking setup failed. Deliver the failure as the original task's result.
        dispatch_completion(task, error: e)
        return
      end
      return unless claimed

      redirect_url = resolve_redirect_url(task.request.url, location)
      @config.logger&.debug("[PatientHttp] Request #{task.id} redirected (#{status}) to #{redirect_url}")

      finish_task(task)
      @testing_callback&.call(task) if PatientHttp.testing?
    end

    # Handles an error response. The caller must have claimed the task with
    # {#claim_task}, so that the result is delivered exactly once.
    #
    # @param task [RequestTask] The request task.
    # @param exception [Exception] The exception.
    # @return [Exception, nil] The delivery failure, or nil on success.
    def handle_error(task, exception)
      failure = deliver_with_retries(task) { task.error!(exception) }

      if failure
        @config.logger&.error(
          "[PatientHttp] Failed to enqueue error worker for request #{task.id}: " \
          "#{failure.class} - #{failure.message}"
        )
      else
        @config.logger&.warn(
          "[PatientHttp] Request #{task.id} failed with #{exception.class.name}: #{exception.message}, " \
          "enqueued callback #{task.callback}\n#{exception.backtrace&.join("\n")}"
        )
      end

      failure
    end

    # Announces a task to the observers and makes it visible to the reactor.
    #
    # The task is announced before it can start, finish, or be re-enqueued, so that
    # the observers can set up durable tracking first. An error from the
    # `request_enqueued` announcement propagates and rejects the task, because a
    # failed tracking setup must not let the task be accepted as if it were durable.
    #
    # The block runs while the task lock is held and decides whether the task is
    # accepted. When the block returns false or raises an error, the observers receive
    # `request_rejected`, so that they can tear down anything that they set up for the
    # `request_enqueued` announcement. The rejection notification never replaces an
    # exception that is already being raised.
    #
    # @param task [RequestTask] The request task to announce and enqueue.
    # @yield A block that decides whether the task is accepted.
    # @return [Boolean] Whether the task was accepted.
    def announce_and_enqueue(task)
      task.enqueued!
      accepted = false

      begin
        notify_observers! { |observer| observer.request_enqueued(task) }

        @tasks_lock.synchronize do
          if yield
            @queued_tasks[task.id] = task
            @queue.push(task)
            accepted = true
          end
        end
      ensure
        unless accepted
          pending_error = $!
          begin
            notify_observers { |observer| observer.request_rejected(task) }
          rescue
            raise unless pending_error
          end
        end
      end

      accepted
    end

    # Notifies all observers of an event. The observers run outside every internal
    # lock, so that they can safely call back into the processor.
    def notify_observers(&block)
      observers = @tasks_lock.synchronize { @observers.dup }
      observers.each do |observer|
        notify_observer(observer, &block)
      end
    end

    # Notifies all observers of an event and lets the errors from the observers
    # propagate. This is used for the notifications that the caller must be able to
    # react to, such as the durable tracking setup in `request_enqueued`.
    def notify_observers!
      observers = @tasks_lock.synchronize { @observers.dup }
      observers.each do |observer|
        yield(observer)
      end
    end

    def notify_observer(observer)
      yield(observer)
    rescue => e
      @config.logger&.error(
        "[PatientHttp] Observer #{observer.class.name} error: #{e.class} - #{e.message}"
      )
      raise e if PatientHttp.testing?
    end

    def reenqueue_pending_requests
      reenqueue_tasks(drain_tracked_tasks)
    end

    # Changes the state to stopped and removes all tracked tasks, both in-flight and
    # pending, and returns them so that the caller can re-enqueue them. The operation
    # is atomic.
    #
    # This method acquires the task lock, so the caller must not already hold it. Use
    # {#drain_tracked_tasks_locked} when the lock is already held.
    #
    # @return [Array<RequestTask>] The tasks that were tracked.
    def drain_tracked_tasks
      @tasks_lock.synchronize { drain_tracked_tasks_locked }
    end

    # Changes the state to stopped and removes all tracked tasks. The caller must hold
    # the task lock.
    #
    # @return [Array<RequestTask>] The tasks that were tracked.
    def drain_tracked_tasks_locked
      @lifecycle.stopped!
      tasks = @inflight_requests.values + @pending_tasks.values
      @inflight_requests.clear
      @pending_tasks.clear
      # Wake any stop() thread blocked on the idle condition. Without this, a
      # reactor-side drain, for example after a crash during shutdown, would clear the
      # tracking hashes without signalling, leaving stop() asleep until its
      # full timeout elapses.
      @idle_condition.broadcast
      tasks
    end

    def reenqueue_remaining_queue_items
      tasks_to_reenqueue = @tasks_lock.synchronize do
        tasks = []

        # Drain remaining items from the queue (skip nil sentinels from stop)
        until @queue.empty?
          begin
            task = @queue.pop(true)
            tasks << task if task
          rescue ThreadError
            break
          end
        end

        tasks.each { |task| @queued_tasks.delete(task.id) }
        # The reactor has exited and no new tasks can be accepted, so any id
        # still tracked as queued belongs to a task that left the queue
        # without reaching pending or in-flight tracking. Reclaim those tasks
        # as well so they are not tracked forever.
        tasks.concat(@queued_tasks.values)
        @queued_tasks.clear
        tasks
      end

      reenqueue_tasks(tasks_to_reenqueue)
    end

    def reenqueue_tasks(tasks_to_reenqueue)
      tasks_to_reenqueue.each do |task|
        task.retry
        # The task handler's job system owns the request again; let observers
        # tear down any durable tracking for the task. Only sent after a
        # successful retry so a failed retry leaves the tracking in place.
        notify_observers { |observer| observer.request_requeued(task) }
        # Only emit request_end for tasks that actually started, so observers
        # that pair request_start with request_end, such as an in-flight gauge, stay
        # balanced. Queued-but-never-started tasks emit neither.
        notify_observers { |observer| observer.request_end(task) } if task.started?

        @config.logger&.info(
          "[PatientHttp] Retrying incomplete request #{task.id}"
        )
      rescue => e
        @config.logger&.error(
          "[PatientHttp] Failed to re-enqueue request #{task.id}: #{e.class} - #{e.message}"
        )

        raise if PatientHttp.testing?
      end
    end
  end
end
