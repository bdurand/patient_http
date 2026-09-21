# frozen_string_literal: true

module PatientHttp
  module PayloadStore
    # Redis-based payload store for production deployments.
    #
    # Stores payloads as JSON strings in Redis. This store is recommended
    # for production environments where multiple processes need to share
    # payload data.
    #
    # Thread-safe: Redis clients handle their own thread safety.
    #
    # The client must respond to `set`, `get`, `del`, and `exists` (the
    # interface provided by the `redis` gem).
    #
    # @example Configuration with direct Redis client
    #   redis = Redis.new(url: ENV["REDIS_URL"])
    #   config.register_payload_store(:redis, adapter: :redis, redis: redis, ttl: 86400)
    class RedisStore < Base
      Base.register :redis, self

      # @return [String] the key prefix used for all stored payloads
      attr_reader :key_prefix

      # @return [Float, nil] TTL in seconds for stored payloads
      attr_reader :ttl

      # Initialize a new Redis store.
      #
      # @param redis [Object] Redis client instance (required)
      # @param ttl [Float, nil] time-to-live in seconds for stored payloads. Fractional
      #   seconds are supported (e.g., 0.5 for 500 milliseconds). If nil, payloads do
      #   not expire.
      # @param key_prefix [String] prefix for all Redis keys; defaults to
      #   "patient_http:payloads:"
      # @raise [ArgumentError] if the Redis client is not provided
      def initialize(redis:, ttl: nil, key_prefix: nil)
        raise ArgumentError, "redis client is required" unless redis

        @redis = redis
        @ttl = ttl
        @key_prefix = key_prefix || "patient_http:payloads:"
      end

      # Store pre-serialized JSON string directly in Redis.
      #
      # @param key [String] unique key (appended to key_prefix)
      # @param json [String] pre-serialized JSON string
      # @return [String] the key
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

      # Fetch data from Redis.
      #
      # @param key [String] the key to fetch
      # @return [Hash, nil] the stored data or nil if not found
      def fetch(key)
        full_key = key_with_prefix(key)
        json = @redis.get(full_key)
        return nil if json.nil?

        JSON.parse(json)
      end

      # Delete a payload from Redis.
      #
      # Idempotent—does not raise if key does not exist.
      #
      # @param key [String] the key to delete
      # @return [Boolean] true
      def delete(key)
        full_key = key_with_prefix(key)
        @redis.del(full_key)
        true
      end

      # Check whether a payload exists.
      #
      # @param key [String] the key to check
      # @return [Boolean] true if the payload exists
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
