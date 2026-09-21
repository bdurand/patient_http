# frozen_string_literal: true

module PatientHttp
  # Fixed pool of worker threads that deliver completed request results.
  #
  # The reactor thread of the processor hands each finished HTTP exchange to this
  # pool, so that response decoding, serialization, and callback delivery never block
  # the event loop. Jobs are arbitrary callables that the workers consume from a
  # single queue.
  #
  # @api private
  class CompletionExecutor
    # Initializes the executor and starts its worker threads.
    #
    # @param threads [Integer] The number of worker threads.
    # @param logger [Logger, nil] The logger for unexpected job errors.
    # @param thread_name_prefix [String] The prefix for worker thread names.
    # @param on_finished [#call, nil] A callable that runs after each job completes,
    #   outside any executor lock, so that the owner can check the idle conditions
    #   again.
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

    # Enqueues a job to run.
    #
    # @param job [#call] The job to run.
    # @return [void]
    # @raise [ClosedQueueError] If the executor is shut down.
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

    # Checks whether the executor has no queued or running jobs.
    #
    # @return [Boolean] Whether the executor is idle.
    def idle?
      @mutex.synchronize { @outstanding == 0 }
    end

    # Checks whether the given thread is one of the workers of this executor.
    #
    # @param thread [Thread] The thread to check.
    # @return [Boolean] Whether the thread is a worker thread.
    def worker_thread?(thread = Thread.current)
      @threads.include?(thread)
    end

    # Shuts down the executor. The queue is closed so that the workers drain the
    # remaining jobs and exit, and the workers are then joined within the timeout. A
    # worker that is still alive after the deadline is stopped. Its tasks stay
    # durably tracked, and the re-enqueue logic of the owner recovers them.
    #
    # You can call this method more than once, and from a worker thread itself. The
    # current thread is never joined or stopped.
    #
    # @param timeout [Numeric] The number of seconds to wait for the workers to
    #   drain.
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

    # Drops the jobs that are left in the closed queue by workers that were stopped at
    # the shutdown deadline. Those jobs can never run, so they must stop counting
    # against the outstanding total. Otherwise the executor never reports itself as
    # idle again.
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
