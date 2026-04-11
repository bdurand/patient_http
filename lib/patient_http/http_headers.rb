# frozen_string_literal: true

module PatientHttp
  # Case insensitive HTTP headers.
  #
  # This class provides a hash-like interface for HTTP headers with case-insensitive
  # key access. Header names are normalized to lowercase for storage and lookup.
  class HttpHeaders
    include Enumerable

    # Initializes a new HttpHeaders instance.
    #
    # @param headers [Hash] initial headers to set
    def initialize(headers = {})
      @headers = {}
      headers&.each do |key, value|
        @headers[key.to_s.downcase] = value
      end
    end

    # Retrieves the value for a header (case insensitive).
    #
    # @param key [String, Symbol] header name
    # @return [String, nil] header value or nil if not found
    def [](key)
      @headers[key.to_s.downcase]
    end

    # Sets the value for a header (case insensitive).
    #
    # @param key [String, Symbol] header name
    # @param value [String] header value
    def []=(key, value)
      @headers[key.to_s.downcase] = value
    end

    # Fetches the value for a header with an optional default.
    #
    # @param key [String, Symbol] header name
    # @param default [Object] default value if header not found
    # @return [String, Object] header value or default
    def fetch(key, default = nil)
      @headers.fetch(key.to_s.downcase, default)
    end

    # Merges another set of headers into a new HttpHeaders instance.
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

    # Returns a new HttpHeaders without the specified keys (case-insensitive).
    #
    # @param keys [Array<String, Symbol>] header names to exclude
    # @return [HttpHeaders] new instance without the specified headers
    def except(*keys)
      normalized = keys.map { |k| k.to_s.downcase }
      self.class.new(@headers.except(*normalized))
    end

    # Converts to a regular hash with lowercase keys.
    #
    # @return [Hash] hash representation
    def to_h
      @headers.dup
    end

    # Iterates over each header.
    #
    # @yield [key, value] yields each header key-value pair
    # @return [Enumerator] if no block given
    def each(&block)
      @headers.each(&block)
    end

    # Checks if a header exists (case insensitive).
    #
    # @param name [String, Symbol] header name
    # @return [Boolean] true if header exists
    def include?(name)
      @headers.include?(name.to_s.downcase)
    end

    def eql?(other)
      other.is_a?(HttpHeaders) && @headers.eql?(other.to_h)
    end

    def hash
      @headers.hash
    end
  end
end
