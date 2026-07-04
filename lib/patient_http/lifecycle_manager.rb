# frozen_string_literal: true

module PatientHttp
  # Manages the lifecycle state of the Processor.
  #
  # Handles state transitions and provides predicates for checking the current state.
  # Thread-safe state management using Concurrent::AtomicReference.
  class LifecycleManager
    include TimeHelper

    # Valid processor states
    STATES = %i[stopped starting running draining stopping].freeze

    # Polling interval during wait operations
    POLL_INTERVAL = 0.01

    # Initialize the lifecycle manager.
    #
    # @return [void]
    def initialize
      @state = Concurrent::AtomicReference.new(:stopped)
      @shutdown_barrier = Concurrent::Event.new
      @reactor_ready = Concurrent::Event.new
      @lock = Mutex.new
    end

    # Get the current state.
    #
    # @return [Symbol] the current state
    def state
      @state.get
    end

    # Check if processor is starting.
    #
    # @return [Boolean] true if starting
    def starting?
      state == :starting
    end

    # Check if processor is running.
    #
    # @return [Boolean] true if running
    def running?
      state == :running
    end

    # Check if processor is stopped.
    #
    # @return [Boolean] true if stopped
    def stopped?
      state == :stopped
    end

    # Check if processor is draining.
    #
    # @return [Boolean] true if draining
    def draining?
      state == :draining
    end

    # Check if processor is stopping.
    #
    # @return [Boolean] true if stopping
    def stopping?
      state == :stopping
    end

    # Transition to starting state. The processor can only be started from
    # the stopped state; in particular, starting a draining processor would
    # spawn a second reactor alongside the one still finishing its drain.
    #
    # @return [Boolean] true if transition was successful
    def start!
      @lock.synchronize do
        return false unless stopped?

        @state.set(:starting)
        @shutdown_barrier.reset
        @reactor_ready.reset
      end

      true
    end

    # Transition to running state.
    #
    # The transition only occurs from the starting state so that a reactor
    # that already failed and transitioned to stopped is not overwritten.
    #
    # @return [Boolean] true if transition was successful
    def running!
      @lock.synchronize do
        return false unless starting?

        @state.set(:running)
      end

      true
    end

    # Transition to draining state.
    #
    # @return [Boolean] true if transition was successful
    def drain!
      @lock.synchronize do
        return false unless running?

        @state.set(:draining)
      end

      true
    end

    # Transition to stopping state.
    #
    # @return [Boolean] true if transition was successful
    def stop!
      @lock.synchronize do
        return false if stopped? || stopping? || starting?

        @state.set(:stopping)
        @shutdown_barrier.set
      end

      true
    end

    # Transition to stopped state.
    #
    # Also signals the reactor_ready event to unblock any thread
    # waiting in {#wait_for_reactor} in case the reactor failed
    # before it could signal readiness.
    #
    # @return [void]
    def stopped!
      @state.set(:stopped)
      @reactor_ready.set
    end

    # Signal that the reactor is ready.
    #
    # @return [void]
    def reactor_ready!
      @reactor_ready.set
    end

    # Wait for the reactor to be ready.
    #
    # @param timeout [Numeric, nil] maximum time to wait in seconds (nil waits forever)
    # @return [Boolean] true if the reactor is ready, false if the timeout was reached
    def wait_for_reactor(timeout: nil)
      @reactor_ready.wait(timeout)
    end

    # Check if shutdown has been signaled.
    #
    # @return [Boolean] true if shutdown is signaled
    def shutdown_signaled?
      @shutdown_barrier.set?
    end

    # Wait for running state.
    #
    # @param timeout [Numeric] maximum time to wait in seconds
    # @return [Boolean] true if running, false if timeout reached
    def wait_for_running(timeout: 5)
      wait_for_condition(timeout: timeout) { running? }
    end

    # Wait for a condition to be met.
    #
    # @param timeout [Numeric] maximum time to wait in seconds
    # @yield Block that checks the condition.
    # @return [Boolean] true if the condition is met, false if timeout reached
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
