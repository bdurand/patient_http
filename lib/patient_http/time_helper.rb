# frozen_string_literal: true

module PatientHttp
  # Helper module for time-related operations using monotonic and wall-clock time.
  #
  # This module provides utilities for accurate timing measurements that are immune
  # to system clock changes, as well as conversion between monotonic and wall-clock time.
  module TimeHelper
    extend self

    # Get the current monotonic time.
    #
    # Monotonic time is guaranteed to be non-decreasing and immune to system clock changes.
    #
    # @return [Float] current monotonic time in seconds since an unspecified starting point
    def monotonic_time
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    # Convert a monotonic timestamp to wall-clock time.
    #
    # @param monotonic_timestamp [Float] monotonic timestamp to convert
    # @return [Time] wall-clock time corresponding to the monotonic timestamp
    def wall_clock_time(monotonic_timestamp)
      return nil unless monotonic_timestamp

      now = Time.now
      elapsed = monotonic_time - monotonic_timestamp
      now - elapsed
    end
  end
end
