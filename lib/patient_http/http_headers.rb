# frozen_string_literal: true

module PatientHttp
  # Case-insensitive HTTP headers.
  #
  # This class provides a hash-like interface for HTTP headers with case-insensitive
  # key access. Header names are normalized to lowercase for storage and lookup.
  #
  # Headers with an empty value are never stored. Setting a header to nil or an
  # empty string removes it, so a request never sends a header with no value.
  class HttpHeaders
    include Enumerable

    # Initialize a new HttpHeaders instance. Entries with a nil or empty value
    # are skipped.
    #
    # @param headers [Hash, HttpHeaders] initial headers to set
    def initialize(headers = {})
      @headers = {}
      headers&.each do |key, value|
        self[key] = value
      end
    end

    # Retrieve the value for a header (case insensitive).
    #
    # @param key [String, Symbol] header name
    # @return [String, nil] header value or nil if not found
    def [](key)
      @headers[key.to_s.downcase]
    end

    # Set the value for a header (case insensitive). Setting a header to nil
    # or an empty string removes it.
    #
    # @param key [String, Symbol] header name
    # @param value [String, nil] header value
    def []=(key, value)
      name = key.to_s.downcase
      if empty_value?(value)
        @headers.delete(name)
      else
        @headers[name] = value
      end
    end

    # Remove a header (case insensitive).
    #
    # @param key [String, Symbol] header name
    # @return [String, nil] the removed value or nil if not found
    def delete(key)
      @headers.delete(key.to_s.downcase)
    end

    # Fetch the value for a header with an optional default.
    #
    # @param key [String, Symbol] header name
    # @param default [Object] default value if the header is not found
    # @return [String, Object] header value or the default
    def fetch(key, default = nil)
      @headers.fetch(key.to_s.downcase, default)
    end

    # Merge another set of headers into a new HttpHeaders instance.
    #
    # @param other_headers [Hash, HttpHeaders] headers to merge
    # @return [HttpHeaders] new instance with merged headers
    def merge(other_headers)
      new_headers = dup
      other_headers.each do |key, value|
        new_headers[key] = value
      end
      new_headers
    end

    # Return a new HttpHeaders without the specified keys (case insensitive).
    #
    # @param keys [Array<String, Symbol>] header names to exclude
    # @return [HttpHeaders] new instance without the specified headers
    def except(*keys)
      normalized = keys.map { |k| k.to_s.downcase }
      filtered_headers = @headers.reject { |key, _value| normalized.include?(key) } # rubocop:disable Style/HashExcept
      self.class.new(filtered_headers)
    end

    # Convert to a regular hash with lowercase keys.
    #
    # @return [Hash] hash representation
    def to_h
      @headers.dup
    end

    # Iterate over each header.
    #
    # @yield [key, value] yields each header key-value pair
    # @return [Enumerator] if no block is given
    def each(&block)
      @headers.each(&block)
    end

    # Check whether a header exists (case insensitive).
    #
    # @param name [String, Symbol] header name
    # @return [Boolean] true if the header exists
    def include?(name)
      @headers.include?(name.to_s.downcase)
    end

    # Ensure copies do not share the underlying storage so that mutating a
    # copy (for example, via #merge) does not modify the original.
    def initialize_copy(other)
      super
      @headers = @headers.dup
    end

    def eql?(other)
      other.is_a?(HttpHeaders) && @headers.eql?(other.to_h)
    end

    def hash
      @headers.hash
    end

    private

    # A header value is empty when it is nil or a string with no characters.
    def empty_value?(value)
      value.nil? || (value.is_a?(String) && value.empty?)
    end
  end
end
