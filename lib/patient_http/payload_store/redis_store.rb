# frozen_string_literal: true

module PatientHttp
  module PayloadStore
    # Payload store for production deployments that uses Redis.
    #
    # This store holds payloads as JSON strings in Redis. Use it in production
    # environments where several processes share the payload data.
    #
    # This store is thread-safe, because Redis clients handle their own thread safety.
    #
    # The client must respond to `set`, `get`, `del`, and `exists`, which is the
    # interface that the `redis` gem provides.
    #
    # @example Configuration with direct Redis client
    #   redis = Redis.new(url: ENV["REDIS_URL"])
    #   config.register_payload_store(:redis, adapter: :redis, redis: redis, ttl: 86400)
    class RedisStore < Base
      Base.register :redis, self

      # @return [String] The key prefix for all stored payloads.
      attr_reader :key_prefix

      # @return [Float, nil] The time to live, in seconds, for stored payloads.
      attr_reader :ttl

      # Initializes a new Redis store.
      #
      # @param redis [Object] The Redis client. This parameter is required.
      # @param ttl [Float, nil] The time to live, in seconds, for stored payloads.
      #   Fractional seconds are supported, for example 0.5 for 500 ms. If nil, the
      #   payloads do not expire.
      # @param key_prefix [String] The prefix for all Redis keys. Defaults to
      #   `"patient_http:payloads:"`.
      # @raise [ArgumentError] If no Redis client is provided.
      def initialize(redis:, ttl: nil, key_prefix: nil)
        raise ArgumentError, "redis client is required" unless redis

        @redis = redis
        @ttl = ttl
        @key_prefix = key_prefix || "patient_http:payloads:"
      end

      # Stores a serialized JSON string directly in Redis.
      #
      # @param key [String] A unique key, which is appended to the key prefix.
      # @param json [String] The serialized JSON string.
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

      # Fetches data from Redis.
      #
      # @param key [String] The key to fetch.
      # @return [Hash, nil] The stored data, or nil if the key is not found.
      def fetch(key)
        full_key = key_with_prefix(key)
        json = @redis.get(full_key)
        return nil if json.nil?

        JSON.parse(json)
      end

      # Deletes a payload from Redis.
      #
      # This method is idempotent. It does not raise an error if the key does not
      # exist.
      #
      # @param key [String] The key to delete.
      # @return [Boolean] Always true.
      def delete(key)
        full_key = key_with_prefix(key)
        @redis.del(full_key)
        true
      end

      # Checks whether a payload exists.
      #
      # @param key [String] The key to check.
      # @return [Boolean] Whether the payload exists.
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
