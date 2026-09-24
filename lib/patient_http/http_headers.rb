# frozen_string_literal: true

module PatientHttp
  # Case insensitive HTTP headers.
  #
  # This class provides a hash-like interface for HTTP headers with case-insensitive
  # key access. Header names are stored and looked up in lowercase.
  #
  # Headers with an empty value are never stored. Setting a header to `nil` or an
  # empty string removes it, so a request never sends a header with no value.
  class HttpHeaders
    include Enumerable

    # Creates a set of headers. Entries with a `nil` or empty value are skipped.
    #
    # @param headers [Hash, HttpHeaders] The initial headers.
    def initialize(headers = {})
      @headers = {}
      headers&.each do |key, value|
        self[key] = value
      end
    end

    # Returns the value of a header. The name is case insensitive.
    #
    # @param key [String, Symbol] The header name.
    # @return [String, nil] The header value, or `nil` if it isn't found.
    def [](key)
      @headers[key.to_s.downcase]
    end

    # Sets the value of a header. The name is case insensitive. Setting a header to
    # `nil` or an empty string removes it.
    #
    # @param key [String, Symbol] The header name.
    # @param value [String, nil] The header value.
    def []=(key, value)
      name = key.to_s.downcase
      if empty_value?(value)
        @headers.delete(name)
      else
        @headers[name] = value
      end
    end

    # Removes a header. The name is case insensitive.
    #
    # @param key [String, Symbol] The header name.
    # @return [String, nil] The removed value, or `nil` if the header isn't found.
    def delete(key)
      @headers.delete(key.to_s.downcase)
    end

    # Returns the value of a header, or a default value if the header isn't found.
    #
    # @param key [String, Symbol] The header name.
    # @param default [Object] The value to return if the header isn't found.
    # @return [String, Object] The header value or the default.
    def fetch(key, default = nil)
      @headers.fetch(key.to_s.downcase, default)
    end

    # Returns a new set of headers with another set merged in.
    #
    # @param other_headers [Hash, HttpHeaders] The headers to merge.
    # @return [HttpHeaders] A new object with the merged headers.
    def merge(other_headers)
      new_headers = dup
      other_headers.each do |key, value|
        new_headers[key] = value
      end
      new_headers
    end

    # Returns a new set of headers without the specified names. Names are case
    # insensitive.
    #
    # @param keys [Array<String, Symbol>] The header names to exclude.
    # @return [HttpHeaders] A new object without the specified headers.
    def except(*keys)
      normalized = keys.map { |k| k.to_s.downcase }
      filtered_headers = @headers.reject { |key, _value| normalized.include?(key) } # rubocop:disable Style/HashExcept
      self.class.new(filtered_headers)
    end

    # Converts the headers to a hash with lowercase keys.
    #
    # @return [Hash] The hash representation.
    def to_h
      @headers.dup
    end

    # Iterates over each header.
    #
    # @yield [key, value] Each header name and value.
    # @return [Enumerator] An enumerator, if you don't provide a block.
    def each(&block)
      @headers.each(&block)
    end

    # Returns `true` if a header exists. The name is case insensitive.
    #
    # @param name [String, Symbol] The header name.
    # @return [Boolean] `true` if the header exists.
    def include?(name)
      @headers.include?(name.to_s.downcase)
    end

    # Gives each copy its own storage, so changing a copy, such as with {#merge},
    # doesn't change the original.
    def initialize_copy(other)
      super
      @headers = @headers.dup
    end

    # Returns `true` if another object is an {HttpHeaders} with the same headers.
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

    # Returns `true` if a header value is `nil` or an empty string.
    def empty_value?(value)
      value.nil? || (value.is_a?(String) && value.empty?)
    end
  end
end
