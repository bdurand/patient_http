# frozen_string_literal: true

module PatientHttp
  # Helper methods for monotonic and wall clock time.
  #
  # Use these methods for timing measurements that system clock changes don't
  # affect, and to convert monotonic time to wall clock time.
  module TimeHelper
    extend self

    # Returns the current monotonic time.
    #
    # Monotonic time never decreases, and system clock changes don't affect it.
    #
    # @return [Float] The current monotonic time, in seconds since an unspecified starting point.
    def monotonic_time
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    # Converts a monotonic timestamp to wall clock time.
    #
    # @param monotonic_timestamp [Float] The monotonic timestamp to convert.
    # @return [Time] The wall clock time for the monotonic timestamp.
    def wall_clock_time(monotonic_timestamp)
      return nil unless monotonic_timestamp

      now = Time.now
      elapsed = monotonic_time - monotonic_timestamp
      now - elapsed
    end
  end
end
