# frozen_string_literal: true

module PatientHttp
  # HTTP headers with case-insensitive names.
  #
  # The interface is like a Hash. Names are stored in lowercase.
  #
  # A header with an empty value isn't stored. If you set a header to `nil` or
  # an empty string, the header is removed. As a result, a request never sends
  # a header with no value.
  class HttpHeaders
    include Enumerable

    # Creates a set of headers. Entries with a `nil` or empty value are skipped.
    #
    # @param headers [Hash, HttpHeaders] Initial headers to set.
    def initialize(headers = {})
      @headers = {}
      headers&.each do |key, value|
        self[key] = value
      end
    end

    # Retrieves the value for a header (case insensitive).
    #
    # @param key [String, Symbol] Header name.
    # @return [String, nil] Header value or nil if not found.
    def [](key)
      @headers[key.to_s.downcase]
    end

    # Sets the value for a header (case insensitive). Setting a header to `nil`
    # or an empty string removes it.
    #
    # @param key [String, Symbol] Header name.
    # @param value [String, nil] Header value.
    def []=(key, value)
      name = key.to_s.downcase
      if empty_value?(value)
        @headers.delete(name)
      else
        @headers[name] = value
      end
    end

    # Removes a header (case insensitive).
    #
    # @param key [String, Symbol] Header name.
    # @return [String, nil] The removed value or nil if not found.
    def delete(key)
      @headers.delete(key.to_s.downcase)
    end

    # Fetches the value for a header with an optional default.
    #
    # @param key [String, Symbol] Header name.
    # @param default [Object] Default value if header not found.
    # @return [String, Object] Header value or default.
    def fetch(key, default = nil)
      @headers.fetch(key.to_s.downcase, default)
    end

    # Merges another set of headers into a new HttpHeaders instance.
    #
    # @param other_headers [Hash, HttpHeaders] Headers to merge.
    # @return [HttpHeaders] New instance with merged headers.
    def merge(other_headers)
      new_headers = dup
      other_headers.each do |key, value|
        new_headers[key] = value
      end
      new_headers
    end

    # Returns a new HttpHeaders without the specified keys (case-insensitive).
    #
    # @param keys [Array<String, Symbol>] Header names to exclude.
    # @return [HttpHeaders] New instance without the specified headers.
    def except(*keys)
      normalized = keys.map { |k| k.to_s.downcase }
      filtered_headers = @headers.reject { |key, _value| normalized.include?(key) } # rubocop:disable Style/HashExcept
      self.class.new(filtered_headers)
    end

    # Converts to a regular hash with lowercase keys.
    #
    # @return [Hash] Hash representation.
    def to_h
      @headers.dup
    end

    # Iterates over each header.
    #
    # @yield [key, value] Yields each header key-value pair.
    # @return [Enumerator] If no block given.
    def each(&block)
      @headers.each(&block)
    end

    # Returns whether a header exists (case insensitive).
    #
    # @param name [String, Symbol] Header name.
    # @return [Boolean] `true` if header exists.
    def include?(name)
      @headers.include?(name.to_s.downcase)
    end

    # Ensures copies do not share the underlying storage so that mutating a
    # copy (for example, via #merge) does not modify the original.
    def initialize_copy(other)
      super
      @headers = @headers.dup
    end

    # Returns whether another object has the same headers.
    #
    # @param other [Object] The object to compare.
    # @return [Boolean] `true` if the headers are equal.
    def eql?(other)
      other.is_a?(HttpHeaders) && @headers.eql?(other.to_h)
    end

    # Returns a hash code based on the headers.
    #
    # @return [Integer] The hash code.
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
