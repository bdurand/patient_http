# frozen_string_literal: true

module PatientHttp
  # Manages the lifecycle state of the {Processor}.
  #
  # This class handles state transitions and provides predicates for checking the
  # current state. It stores the state in a `Concurrent::AtomicReference`, so it's
  # thread-safe.
  class LifecycleManager
    include TimeHelper

    # The valid processor states.
    STATES = %i[stopped starting running draining stopping].freeze

    # The polling interval for wait operations, in seconds.
    POLL_INTERVAL = 0.01

    # Creates a lifecycle manager.
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

    # Returns `true` if the processor is starting.
    #
    # @return [Boolean] `true` if the processor is starting.
    def starting?
      state == :starting
    end

    # Returns `true` if the processor is running.
    #
    # @return [Boolean] `true` if the processor is running.
    def running?
      state == :running
    end

    # Returns `true` if the processor is stopped.
    #
    # @return [Boolean] `true` if the processor is stopped.
    def stopped?
      state == :stopped
    end

    # Returns `true` if the processor is draining.
    #
    # @return [Boolean] `true` if the processor is draining.
    def draining?
      state == :draining
    end

    # Returns `true` if the processor is stopping.
    #
    # @return [Boolean] `true` if the processor is stopping.
    def stopping?
      state == :stopping
    end

    # Transitions to the starting state. The processor can start only from the
    # stopped state. Starting a draining processor would create a second reactor
    # next to the one that is still draining.
    #
    # @return [Boolean] `true` if the transition succeeded.
    def start!
      @lock.synchronize do
        return false unless stopped?

        @state.set(:starting)
        @shutdown_barrier.reset
        @reactor_ready.reset
      end

      true
    end

    # Transitions to the running state.
    #
    # The transition happens only from the starting state, so it doesn't overwrite
    # the state of a reactor that already failed and stopped.
    #
    # @return [Boolean] `true` if the transition succeeded.
    def running!
      @lock.synchronize do
        return false unless starting?

        @state.set(:running)
      end

      true
    end

    # Transitions to the draining state.
    #
    # @return [Boolean] `true` if the transition succeeded.
    def drain!
      @lock.synchronize do
        return false unless running?

        @state.set(:draining)
      end

      true
    end

    # Transitions to the stopping state.
    #
    # @return [Boolean] `true` if the transition succeeded.
    def stop!
      @lock.synchronize do
        return false if stopped? || stopping? || starting?

        @state.set(:stopping)
        @shutdown_barrier.set
      end

      true
    end

    # Transitions to the stopped state.
    #
    # This method also signals the `reactor_ready` event. The signal unblocks any
    # thread that is waiting in {#wait_for_reactor} if the reactor failed before
    # it could signal that it was ready.
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

    # Waits for the reactor to be ready.
    #
    # @param timeout [Numeric, nil] The maximum time to wait, in seconds. `nil` waits forever.
    # @return [Boolean] `true` if the reactor is ready, or `false` if the timeout was reached.
    def wait_for_reactor(timeout: nil)
      @reactor_ready.wait(timeout)
    end

    # Returns `true` if shutdown has been signaled.
    #
    # @return [Boolean] `true` if shutdown has been signaled.
    def shutdown_signaled?
      @shutdown_barrier.set?
    end

    # Waits for the running state.
    #
    # @param timeout [Numeric] The maximum time to wait, in seconds.
    # @return [Boolean] `true` if the processor is running, or `false` if the timeout was reached.
    def wait_for_running(timeout: 5)
      wait_for_condition(timeout: timeout) { running? }
    end

    # Waits for a condition to be met.
    #
    # @param timeout [Numeric] The maximum time to wait, in seconds.
    # @yield A block that checks the condition.
    # @return [Boolean] `true` if the condition is met, or `false` if the timeout was reached.
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
