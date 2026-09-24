# frozen_string_literal: true

module PatientHttp
  module PayloadStore
    # A payload store that keeps payloads as JSON strings in Redis. Use it in
    # production when several processes share payloads.
    #
    # The client must respond to `set`, `get`, `del`, and `exists`, like a client
    # from the `redis` gem. The client is responsible for thread safety.
    #
    # @example Register a Redis store
    #   redis = Redis.new(url: ENV["REDIS_URL"])
    #   config.register_payload_store(:redis, adapter: :redis, redis: redis, ttl: 86400)
    class RedisStore < Base
      Base.register :redis, self

      # @return [String] The prefix for the keys of all stored payloads.
      attr_reader :key_prefix

      # @return [Float, nil] The time to live in seconds for stored payloads.
      attr_reader :ttl

      # Creates a Redis store.
      #
      # @param redis [Object] The Redis client.
      # @param ttl [Float, nil] The time to live in seconds for stored payloads.
      #   Fractions are allowed, for example `0.5` for 500 milliseconds. If `nil`,
      #   payloads don't expire.
      # @param key_prefix [String] The prefix for all Redis keys.
      # @raise [ArgumentError] If the Redis client is missing.
      def initialize(redis:, ttl: nil, key_prefix: nil)
        raise ArgumentError, "redis client is required" unless redis

        @redis = redis
        @ttl = ttl
        @key_prefix = key_prefix || "patient_http:payloads:"
      end

      # Stores a JSON string in Redis.
      #
      # @param key [String] The unique key. The Redis key is the key prefix and
      #   this key.
      # @param json [String] The serialized JSON.
      # @return [String] The key.
      def store_json(key, json)
        full_key = key_with_prefix(key)

        if @ttl
          ttl_ms = (@ttl * 1000).round
          @redis.set(full_key, json, px: ttl_ms)
        else
          @redis.set(full_key, json)
        end
        key
      end

      # Fetches stored data.
      #
      # @param key [String] The key.
      # @return [Hash, nil] The parsed data, or `nil` if the key isn't found.
      def fetch(key)
        full_key = key_with_prefix(key)
        json = @redis.get(full_key)
        return nil if json.nil?

        JSON.parse(json)
      end

      # Deletes stored data. Doesn't raise an error if the key doesn't exist.
      #
      # @param key [String] The key.
      # @return [Boolean] `true`.
      def delete(key)
        full_key = key_with_prefix(key)
        @redis.del(full_key)
        true
      end

      # Returns whether a payload exists.
      #
      # @param key [String] The key.
      # @return [Boolean] `true` if the payload exists.
      def exists?(key)
        full_key = key_with_prefix(key)
        @redis.exists(full_key) > 0
      end

      private

      def key_with_prefix(key)
        "#{@key_prefix}#{key}"
      end
    end
  end
end
