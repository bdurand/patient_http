# frozen_string_literal: true

module PatientHttp
  # Helper module for time-related operations that use monotonic and wall clock time.
  #
  # This module measures durations accurately even when the system clock changes, and
  # converts between monotonic time and wall clock time.
  module TimeHelper
    extend self

    # Returns the current monotonic time.
    #
    # Monotonic time never decreases and is not affected by system clock changes.
    #
    # @return [Float] The current monotonic time, in seconds since an unspecified
    #   starting point.
    def monotonic_time
      ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
    end

    # Converts a monotonic timestamp to wall clock time.
    #
    # @param monotonic_timestamp [Float] The monotonic timestamp to convert.
    # @return [Time] The wall clock time that corresponds to the monotonic timestamp.
    def wall_clock_time(monotonic_timestamp)
      return nil unless monotonic_timestamp

      now = Time.now
      elapsed = monotonic_time - monotonic_timestamp
      now - elapsed
    end
  end
end
