# frozen_string_literal: true

module PatientHttp
  # Manages the lifecycle state of a {Processor}.
  #
  # This class performs the state transitions and reports the current state. State
  # management is thread-safe and uses `Concurrent::AtomicReference`.
  #
  # @api private
  class LifecycleManager
    include TimeHelper

    # The valid processor states.
    STATES = %i[stopped starting running draining stopping].freeze

    # The polling interval, in seconds, for the wait operations.
    POLL_INTERVAL = 0.01

    # Initializes a new LifecycleManager.
    #
    # @return [void]
    def initialize
      @state = Concurrent::AtomicReference.new(:stopped)
      @shutdown_barrier = Concurrent::Event.new
      @reactor_ready = Concurrent::Event.new
      @lock = Mutex.new
    end

    # Returns the current state.
    #
    # @return [Symbol] The current state.
    def state
      @state.get
    end

    # Checks whether the processor is starting.
    #
    # @return [Boolean] Whether the processor is starting.
    def starting?
      state == :starting
    end

    # Checks whether the processor is running.
    #
    # @return [Boolean] Whether the processor is running.
    def running?
      state == :running
    end

    # Checks whether the processor is stopped.
    #
    # @return [Boolean] Whether the processor is stopped.
    def stopped?
      state == :stopped
    end

    # Checks whether the processor is draining.
    #
    # @return [Boolean] Whether the processor is draining.
    def draining?
      state == :draining
    end

    # Checks whether the processor is stopping.
    #
    # @return [Boolean] Whether the processor is stopping.
    def stopping?
      state == :stopping
    end

    # Changes the state to starting. You can start the processor only from the
    # stopped state. Starting a draining processor would create a second reactor
    # next to the one that is still finishing its drain.
    #
    # @return [Boolean] Whether the transition was successful.
    def start!
      @lock.synchronize do
        return false unless stopped?

        @state.set(:starting)
        @shutdown_barrier.reset
        @reactor_ready.reset
      end

      true
    end

    # Changes the state to running.
    #
    # The transition happens only from the starting state, so that a reactor that
    # already failed and moved to the stopped state is not overwritten.
    #
    # @return [Boolean] Whether the transition was successful.
    def running!
      @lock.synchronize do
        return false unless starting?

        @state.set(:running)
      end

      true
    end

    # Changes the state to draining.
    #
    # @return [Boolean] Whether the transition was successful.
    def drain!
      @lock.synchronize do
        return false unless running?

        @state.set(:draining)
      end

      true
    end

    # Changes the state to stopping.
    #
    # @return [Boolean] Whether the transition was successful.
    def stop!
      @lock.synchronize do
        return false if stopped? || stopping? || starting?

        @state.set(:stopping)
        @shutdown_barrier.set
      end

      true
    end

    # Changes the state to stopped.
    #
    # This method also signals the reactor ready event, which unblocks any thread that
    # waits in {#wait_for_reactor} if the reactor failed before it could signal that
    # it was ready.
    #
    # @return [void]
    def stopped!
      @state.set(:stopped)
      @reactor_ready.set
    end

    # Signals that the reactor is ready.
    #
    # @return [void]
    def reactor_ready!
      @reactor_ready.set
    end

    # Waits for the reactor to become ready.
    #
    # @param timeout [Numeric, nil] The maximum time to wait, in seconds. Use nil to
    #   wait without a limit.
    # @return [Boolean] Whether the reactor is ready. False means that the timeout was
    #   reached.
    def wait_for_reactor(timeout: nil)
      @reactor_ready.wait(timeout)
    end

    # Checks whether a shutdown was signaled.
    #
    # @return [Boolean] Whether a shutdown was signaled.
    def shutdown_signaled?
      @shutdown_barrier.set?
    end

    # Waits for the running state.
    #
    # @param timeout [Numeric] The maximum time to wait, in seconds.
    # @return [Boolean] Whether the processor is running. False means that the timeout
    #   was reached.
    def wait_for_running(timeout: 5)
      wait_for_condition(timeout: timeout) { running? }
    end

    # Waits for a condition to be met.
    #
    # @param timeout [Numeric] The maximum time to wait, in seconds.
    # @yield A block that checks the condition.
    # @return [Boolean] Whether the condition was met. False means that the timeout
    #   was reached.
    def wait_for_condition(timeout: 1)
      deadline = monotonic_time + timeout
      while monotonic_time <= deadline
        return true if yield

        sleep(POLL_INTERVAL)
      end
      false
    end
  end
end
