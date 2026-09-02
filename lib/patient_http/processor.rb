# frozen_string_literal: true

module PatientHttp
  # Core processor that handles async HTTP requests in a dedicated thread
  class Processor
    include TimeHelper
    include RedirectHelper

    # Timing constants for the reactor loop
    DEQUEUE_TIMEOUT = 1.0 # Seconds to wait when dequeueing requests

    # Base delay between attempts when delivering a completed result fails.
    # The delay grows linearly with each attempt.
    COMPLETION_RETRY_DELAY = 0.5

    # Seconds allowed for the completion executor to drain during shutdown.
    # The reactor's teardown and stop() share this budget so the reactor can
    # never spend longer draining than stop() is willing to wait for it.
    COMPLETION_SHUTDOWN_TIMEOUT = 5

    # @return [Configuration] the configuration object for the processor
    attr_reader :config

    # @return [String] the processor's name; used in thread names so multiple
    #   named processors in one process are distinguishable
    attr_reader :name

    # Callback to invoke after each request. Only available in testing mode.
    # @api private
    attr_accessor :testing_callback

    # Initialize the processor.
    #
    # @param config [Configuration] the configuration object
    # @param name [String, Symbol] optional name to distinguish this processor
    #   when a process runs more than one
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
      # tracked task ids (e.g. for heartbeat updates on queued tasks).
      @queued_tasks = Concurrent::Hash.new
      @tasks_lock = Mutex.new
      @idle_condition = ConditionVariable.new
      @testing_callback = nil
      @http_client = Client.new(self)
      @observers = []
      @completion_executor = nil
    end

    # Start the processor.
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
          # call (e.g. an unhandled error) does not lose in-flight/pending
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

    # Stop the processor.
    #
    # @param timeout [Numeric, nil] how long to wait for in-flight requests (seconds)
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
        # thread itself (e.g. from a task callback or observer), where joining
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

    # Drain the processor (stop accepting new requests).
    #
    # @return [void]
    def drain
      @tasks_lock.synchronize do
        return unless @lifecycle.drain!
      end

      @config.logger&.info("[PatientHttp] Processor draining (no longer accepting new requests)")
    end

    # Enqueue a request task for processing.
    #
    # @param task [RequestTask] the request task to enqueue
    # @raise [NotRunningError] if processor is not running
    # @raise [MaxCapacityError] if at max capacity
    # @return [void]
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

    # Get the current processor state.
    #
    # @return [Symbol] the current state
    def state
      @lifecycle.state
    end

    # Check if processor is starting.
    #
    # @return [Boolean]
    def starting?
      @lifecycle.starting?
    end

    # Check if processor is running.
    #
    # @return [Boolean]
    def running?
      @lifecycle.running?
    end

    # Check if processor is stopped.
    #
    # @return [Boolean]
    def stopped?
      @lifecycle.stopped?
    end

    # Check if processor is draining.
    #
    # @return [Boolean]
    def draining?
      @lifecycle.draining?
    end

    # Check if processor is drained (draining and idle).
    #
    # @return [Boolean]
    def drained?
      @lifecycle.draining? && idle?
    end

    # Check if processor is stopping.
    #
    # @return [Boolean]
    def stopping?
      @lifecycle.stopping?
    end

    # Check if processor is idle (no queued or in-flight requests, and no
    # results still being delivered by the completion executor).
    #
    # @return [Boolean]
    def idle?
      executor = @completion_executor
      tracking_empty = @tasks_lock.synchronize do
        @queue.empty? && @pending_tasks.empty? && @inflight_requests.empty?
      end

      tracking_empty && (executor.nil? || executor.idle?)
    end

    # Check how many more requests the processor can accept before reaching
    # max capacity. This is an advisory value: the authoritative check happens
    # inside {#enqueue}, so a concurrent enqueue can still hit
    # {MaxCapacityError}. It performs no observer notifications and no durable
    # registration, so it is cheap to call before paying enqueue costs.
    #
    # @return [Integer] remaining capacity (never negative)
    def remaining_capacity
      @tasks_lock.synchronize do
        remaining = @config.max_connections - (@queue.size + @pending_tasks.size + @inflight_requests.size)
        (remaining > 0) ? remaining : 0
      end
    end

    # Check if the processor can accept at least one more request. Advisory
    # only; see {#remaining_capacity}.
    #
    # @return [Boolean]
    def capacity_available?
      remaining_capacity > 0
    end

    # Get the number of in-flight requests (actively executing HTTP calls).
    #
    # This does not include queued or pending tasks. For the total pipeline
    # count used by the capacity check, see {#total_count}.
    #
    # @return [Integer]
    def inflight_count
      @inflight_requests.size
    end

    # Get the total number of tasks in the pipeline (queued + pending + in-flight).
    #
    # This is the count used by {#enqueue} for capacity enforcement.
    #
    # @return [Integer]
    def total_count
      @tasks_lock.synchronize do
        @queue.size + @pending_tasks.size + @inflight_requests.size
      end
    end

    # Get the IDs of in-flight requests.
    #
    # @return [Array<String>]
    def inflight_request_ids
      @tasks_lock.synchronize do
        @inflight_requests.keys
      end
    end

    # Get the IDs of all tasks in the pipeline (queued, pending, and in-flight).
    # Use this to keep durable tracking (e.g. heartbeats) alive for tasks the
    # processor has accepted but not yet started.
    #
    # @return [Array<String>]
    def tracked_request_ids
      @tasks_lock.synchronize do
        (@queued_tasks.keys + @pending_tasks.keys + @inflight_requests.keys).uniq
      end
    end

    # Add an observer for processor events.
    #
    # @param observer [ProcessorObserver] the observer to add
    # @return [void]
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

    # Wait for the processor to start.
    #
    # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
    # @return [Boolean] true if started, false if timeout reached
    # @api private
    def wait_for_running(timeout: 5)
      start
      @lifecycle.wait_for_running(timeout: timeout)
    end

    # Wait for the queue to be empty and all in-flight requests to complete.
    # This is mainly for use in tests.
    #
    # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
    # @return [Boolean] true if processing completed, false if timeout reached
    # @api private
    def wait_for_idle(timeout: 1)
      @lifecycle.wait_for_condition(timeout: timeout) { idle? }
    end

    # Wait for at least one request to start processing. This is mainly for use in tests.
    #
    # @param timeout [Numeric] maximum time to wait in seconds (default: 5)
    # @return [Boolean] true if a request started processing, false if timeout reached
    # @api private
    def wait_for_processing(timeout: 1)
      @lifecycle.wait_for_condition(timeout: timeout) do
        !@inflight_requests.empty? || !@pending_tasks.empty?
      end
    end

    # Run the processor in a block. This is intended for use in tests to
    # ensure the processor is started and stopped properly.
    #
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

    # Build a thread name for this processor. The default processor keeps the
    # bare prefix; named processors append their name so multiple processors
    # in one process are distinguishable.
    #
    # @param prefix [String] the base thread name
    # @return [String]
    def thread_name(prefix)
      (@name == "default") ? prefix : "#{prefix}-#{@name}"
    end

    # Run the async reactor loop.
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

    # Dequeue a request task with timeout.
    #
    # @param timeout [Numeric] timeout in seconds
    # @return [RequestTask, nil] the request task or nil if timeout
    def dequeue_request(timeout:)
      @queue.pop(timeout: timeout)
    rescue ThreadError
      # Queue is empty and timeout expired
      nil
    end

    # Process a single HTTP request task.
    #
    # @param task [RequestTask] the request task to process
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

    # Hand off a finished HTTP exchange to the completion executor.
    #
    # @param task [RequestTask] the request task
    # @param response_data [Hash, nil] raw response data on success
    # @param error [Exception, nil] the error on failure
    # @return [void]
    def dispatch_completion(task, response_data: nil, error: nil)
      executor = @completion_executor
      executor.enqueue(-> { run_completion(task, response_data: response_data, error: error) })
    rescue ClosedQueueError
      # The executor is already shut down. The task is still tracked, so the
      # shutdown sequence re-enqueues it.
      nil
    end

    # Deliver a finished result on a completion worker thread: decode the
    # response, claim the task, run the result callbacks, and notify
    # observers. When delivery fails after all retries, request_end is NOT
    # fired so durable tracking (crash-recovery records) stays in place and
    # the request can be recovered instead of silently lost.
    #
    # @param task [RequestTask] the request task
    # @param response_data [Hash, nil] raw response data on success
    # @param error [Exception, nil] the error on failure
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

    # Run a delivery block with bounded retries. Returns nil when the block
    # succeeds or the final exception when all attempts fail. Retries back off
    # linearly; sleeping is safe here because delivery runs on a completion
    # worker thread, not the reactor.
    #
    # The block calls into the task handler, so a retry calls the handler
    # again. A handler that raises after its side effect therefore repeats that
    # side effect; handlers must be idempotent, or completion_retries must be
    # set to zero.
    #
    # @param task [RequestTask] the request task (for log context)
    # @return [Exception, nil] the final failure or nil on success
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

    # Atomically take ownership of delivering a task's result by removing it
    # from in-flight tracking.
    #
    # Returns false when the task has already been claimed by the shutdown
    # sequence (re-enqueued for retry), in which case the result must not be
    # delivered.
    #
    # @param task [RequestTask] the request task
    # @return [Boolean] true if this caller owns delivery of the task's result
    def claim_task(task)
      @tasks_lock.synchronize do
        !@inflight_requests.delete(task.id).nil?
      end
    end

    # Signal idle waiters and notify observers after a claimed task finishes.
    #
    # @param task [RequestTask] the request task
    # @return [void]
    def finish_task(task)
      signal_idle
      notify_observers { |observer| observer.request_end(task) }
    end

    # Broadcast the idle condition when the pipeline is empty. Called after a
    # claimed task finishes and by the completion executor after each job, so
    # stop() waiters wake once the last delivery completes.
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

    # Check whether stop() should keep waiting on the completion executor.
    # When stop is called from a completion worker itself (via a result
    # callback), its own in-progress job would never settle, so it is treated
    # as settled to avoid waiting out the full timeout.
    #
    # @return [Boolean]
    def completion_executor_settled?
      executor = @completion_executor
      executor.nil? || executor.worker_thread? || executor.idle?
    end

    # Handle successful response. The caller must have claimed the task via
    # {#claim_task} so the result is delivered exactly once.
    #
    # @param task [RequestTask] the request task
    # @param response [Response] the response object
    # @return [Exception, nil] the delivery failure or nil on success
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

    # Handle a redirect response on the reactor thread.
    #
    # Redirect errors are handed to the completion executor for delivery.
    # When following a redirect, the original task is removed from in-flight
    # tracking and the redirect task is pushed onto the queue within a single
    # {@tasks_lock} section, so a concurrent {#idle?} never observes a moment
    # where neither is tracked.
    #
    # @param task [RequestTask] the request task
    # @param response_data [Hash] the response data with status, headers, body
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
        # The redirect could not be registered (e.g. durable tracking setup
        # failed). Deliver the failure as the original task's result.
        dispatch_completion(task, error: e)
        return
      end
      return unless claimed

      redirect_url = resolve_redirect_url(task.request.url, location)
      @config.logger&.debug("[PatientHttp] Request #{task.id} redirected (#{status}) to #{redirect_url}")

      finish_task(task)
      @testing_callback&.call(task) if PatientHttp.testing?
    end

    # Handle error response. The caller must have claimed the task via
    # {#claim_task} so the result is delivered exactly once.
    #
    # @param task [RequestTask] the request task
    # @param exception [Exception] the exception
    # @return [Exception, nil] the delivery failure or nil on success
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

    # Announce a task to observers and make it visible to the reactor. The
    # task is announced before it can start, finish, or be re-enqueued, so
    # observers can set up durable tracking first. Errors from the
    # request_enqueued announcement propagate and reject the task, because a
    # failed tracking setup must not let the task be accepted as if it were
    # durable. The block runs while {@tasks_lock} is held and decides whether
    # the task is accepted; when it returns false or raises, observers receive
    # request_rejected so they can tear down anything they set up for the
    # request_enqueued announcement. The rejection notification never replaces
    # an exception that is already being raised.
    #
    # @param task [RequestTask] the request task to announce and enqueue
    # @return [Boolean] true if the task was accepted
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

    # Notify all observers of an event. Observers are called outside of any
    # internal lock so they can safely call back into the processor.
    def notify_observers(&block)
      observers = @tasks_lock.synchronize { @observers.dup }
      observers.each do |observer|
        notify_observer(observer, &block)
      end
    end

    # Notify all observers of an event and let observer errors propagate.
    # Used for notifications the caller must be able to react to, such as
    # durable tracking setup in request_enqueued.
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

    # Atomically transition to stopped and remove all tracked (in-flight and
    # pending) tasks, returning them so the caller can re-enqueue them.
    #
    # Acquires {@tasks_lock}; callers must NOT already hold it. Use
    # {#drain_tracked_tasks_locked} when the lock is already held.
    #
    # @return [Array<RequestTask>] the tasks that were being tracked
    def drain_tracked_tasks
      @tasks_lock.synchronize { drain_tracked_tasks_locked }
    end

    # Transition to stopped and remove all tracked tasks. Must be called with
    # {@tasks_lock} held.
    #
    # @return [Array<RequestTask>] the tasks that were being tracked
    def drain_tracked_tasks_locked
      @lifecycle.stopped!
      tasks = @inflight_requests.values + @pending_tasks.values
      @inflight_requests.clear
      @pending_tasks.clear
      # Wake any stop() thread blocked on the idle condition. Without this, a
      # reactor-side drain (e.g. after a crash during shutdown) would clear the
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
        # that pair request_start/request_end (e.g. an in-flight gauge) stay
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
