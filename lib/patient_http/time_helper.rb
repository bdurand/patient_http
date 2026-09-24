# frozen_string_literal: true

module PatientHttp
  # Measures time with the monotonic clock, which system clock changes don't
  # affect, and converts monotonic times to wall clock times.
  #
  # @api private
  module TimeHelper
    extend self

    # Returns the current monotonic time.
    #
    # Monotonic time is guaranteed to be non-decreasing and immune to system clock changes.
    #
    # @return [Float] Current monotonic time in seconds since an unspecified starting point.
    def monotonic_time
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    # Converts a monotonic timestamp to wall clock time.
    #
    # @param monotonic_timestamp [Float] Monotonic timestamp to convert.
    # @return [Time] Wall clock time corresponding to the monotonic timestamp.
    def wall_clock_time(monotonic_timestamp)
      return nil unless monotonic_timestamp

      now = Time.now
      elapsed = monotonic_time - monotonic_timestamp
      now - elapsed
    end
  end
end
