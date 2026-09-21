# frozen_string_literal: true

module PatientHttp
  # Case insensitive HTTP headers.
  #
  # This class gives you a hash-like interface to HTTP headers with case insensitive
  # key access. Header names are stored and looked up in lowercase.
  #
  # A header with an empty value is never stored. Setting a header to nil or to an
  # empty string removes it, so a request never sends a header with no value.
  class HttpHeaders
    include Enumerable

    # Initializes a new HttpHeaders object. Entries with a nil or empty value are
    # skipped.
    #
    # @param headers [Hash, HttpHeaders] The initial headers to set.
    def initialize(headers = {})
      @headers = {}
      headers&.each do |key, value|
        self[key] = value
      end
    end

    # Returns the value of a header. The header name is case insensitive.
    #
    # @param key [String, Symbol] The header name.
    # @return [String, nil] The header value, or nil if the header is not found.
    def [](key)
      @headers[key.to_s.downcase]
    end

    # Sets the value of a header. The header name is case insensitive. Setting a
    # header to nil or to an empty string removes it.
    #
    # @param key [String, Symbol] The header name.
    # @param value [String, nil] The header value.
    # @return [String, nil] The value that was set.
    def []=(key, value)
      name = key.to_s.downcase
      if empty_value?(value)
        @headers.delete(name)
      else
        @headers[name] = value
      end
    end

    # Removes a header. The header name is case insensitive.
    #
    # @param key [String, Symbol] The header name.
    # @return [String, nil] The removed value, or nil if the header is not found.
    def delete(key)
      @headers.delete(key.to_s.downcase)
    end

    # Returns the value of a header, or a default value.
    #
    # @param key [String, Symbol] The header name.
    # @param default [Object] The value to return if the header is not found.
    # @return [String, Object] The header value, or the default value.
    def fetch(key, default = nil)
      @headers.fetch(key.to_s.downcase, default)
    end

    # Merges another set of headers into a new HttpHeaders object.
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

    # Returns a new HttpHeaders object without the given headers. The header names are
    # case insensitive.
    #
    # @param keys [Array<String, Symbol>] The header names to exclude.
    # @return [HttpHeaders] A new object without the given headers.
    def except(*keys)
      normalized = keys.map { |k| k.to_s.downcase }
      filtered_headers = @headers.reject { |key, _value| normalized.include?(key) } # rubocop:disable Style/HashExcept
      self.class.new(filtered_headers)
    end

    # Converts the headers to a regular hash with lowercase keys.
    #
    # @return [Hash] The hash representation.
    def to_h
      @headers.dup
    end

    # Iterates over each header.
    #
    # @yield [key, value] Each header name and value pair.
    # @return [Enumerator] An enumerator, if no block is given.
    def each(&block)
      @headers.each(&block)
    end

    # Checks whether a header exists. The header name is case insensitive.
    #
    # @param name [String, Symbol] The header name.
    # @return [Boolean] Whether the header exists.
    def include?(name)
      @headers.include?(name.to_s.downcase)
    end

    # Makes sure that a copy does not share the underlying storage, so that changing a
    # copy, for example with {#merge}, does not change the original.
    def initialize_copy(other)
      super
      @headers = @headers.dup
    end

    # Checks whether another object holds the same headers.
    #
    # @param other [Object] The object to compare with.
    # @return [Boolean] Whether the objects hold the same headers.
    def eql?(other)
      other.is_a?(HttpHeaders) && @headers.eql?(other.to_h)
    end

    # Returns the hash code of the headers.
    #
    # @return [Integer] The hash code.
    def hash
      @headers.hash
    end

    private

    # A header value is empty when it is nil, or a string with no characters.
    def empty_value?(value)
      value.nil? || (value.is_a?(String) && value.empty?)
    end
  end
end
