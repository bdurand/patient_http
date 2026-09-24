# frozen_string_literal: true

module PatientHttp
  # A fixed pool of worker threads that deliver the results of completed requests.
  #
  # The processor's reactor thread hands each finished HTTP exchange to this pool,
  # so response decoding, serialization, and callback delivery never block the
  # event loop. Jobs are callables that the workers take from a single queue.
  #
  # @api private
  class CompletionExecutor
    # Creates the executor and starts its worker threads.
    #
    # @param threads [Integer] The number of worker threads.
    # @param logger [Logger, nil] The logger for unexpected job errors.
    # @param thread_name_prefix [String] The prefix for worker thread names.
    # @param on_finished [#call, nil] A callable that runs after each job completes,
    #   outside any executor lock, so the owner can check idle conditions again.
    def initialize(threads:, logger: nil, thread_name_prefix: "patient-http-completion", on_finished: nil)
      @queue = Thread::Queue.new
      @logger = logger
      @on_finished = on_finished
      @mutex = Mutex.new
      # Jobs enqueued but not yet fully executed. Tracked separately from the
      # queue size so a job that has been popped but is still running keeps
      # the executor non-idle.
      @outstanding = 0
      @threads = Array.new(threads) do |index|
        Thread.new do
          Thread.current.name = "#{thread_name_prefix}-#{index + 1}"
          run_worker
        end
      end
    end

    # Enqueues a job.
    #
    # @param job [#call] The job to run.
    # @raise [ClosedQueueError] If the executor has been shut down.
    # @return [void]
    def enqueue(job)
      @mutex.synchronize { @outstanding += 1 }
      begin
        @queue.push(job)
      rescue ClosedQueueError
        @mutex.synchronize { @outstanding -= 1 }
        raise
      end
      nil
    end

    # Returns `true` if the executor has no queued or running jobs.
    #
    # @return [Boolean]
    def idle?
      @mutex.synchronize { @outstanding == 0 }
    end

    # Returns `true` if the given thread is one of this executor's workers.
    #
    # @param thread [Thread] The thread to check.
    # @return [Boolean]
    def worker_thread?(thread = Thread.current)
      @threads.include?(thread)
    end

    # Shuts down the executor. This method closes the queue so workers finish the
    # remaining jobs and exit, and then joins the workers within the timeout. It
    # kills any worker still alive after the deadline. The tasks of killed workers
    # stay tracked, and the owner's re-enqueue logic recovers them.
    #
    # You can call this method more than once, and from a worker thread. It never
    # joins or kills the current thread.
    #
    # @param timeout [Numeric] The number of seconds to wait for workers to finish.
    # @return [void]
    def shutdown(timeout: 5)
      @queue.close

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      @threads.each do |thread|
        next if thread.equal?(Thread.current)

        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        thread.join(remaining.positive? ? remaining : 0)
        if thread.alive?
          thread.kill
          thread.join(1)
        end
      end

      discard_undrained_jobs
      nil
    end

    private

    # Drops jobs left in the closed queue by workers that were killed at the
    # shutdown deadline. Those jobs can never run. If they still counted toward
    # the outstanding total, the executor would never report itself as idle.
    #
    # @return [void]
    def discard_undrained_jobs
      discarded = 0

      loop do
        break unless @queue.pop(true)
        discarded += 1
      rescue ThreadError
        break
      end

      @mutex.synchronize { @outstanding -= discarded } if discarded > 0
      nil
    end

    def run_worker
      while (job = @queue.pop)
        begin
          job.call
        rescue => e
          @logger&.error(
            "[PatientHttp] Completion worker error: #{e.class} - #{e.message}\n#{e.backtrace&.join("\n")}"
          )
          warn("#{e.inspect}\n#{e.backtrace&.join("\n")}") if PatientHttp.testing?
        ensure
          @mutex.synchronize { @outstanding -= 1 }
          begin
            @on_finished&.call
          rescue => e
            @logger&.error("[PatientHttp] Completion executor callback error: #{e.inspect}")
          end
        end
      end
    end
  end
end
