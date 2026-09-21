# frozen_string_literal: true

begin
  require "aws-sdk-s3"
rescue LoadError
  raise LoadError, "The aws-sdk-s3 gem is required to use S3Store. Add it to your Gemfile: gem 'aws-sdk-s3'"
end

module PatientHttp
  module PayloadStore
    # Payload store for production deployments that uses Amazon S3.
    #
    # This store holds payloads as JSON objects in S3. Use it in production
    # environments where the payloads need durable storage and are shared across
    # several processes or instances.
    #
    # This store is thread-safe, because S3 clients handle their own thread safety.
    #
    # @example Configuration with S3 bucket
    #   s3 = Aws::S3::Resource.new
    #   bucket = s3.bucket("my-payloads-bucket")
    #   config.register_payload_store(:s3, adapter: :s3, bucket: bucket)
    class S3Store < Base
      Base.register :s3, self

      # @return [String] The key prefix for all stored payloads.
      attr_reader :key_prefix

      # Initializes a new S3 store.
      #
      # @param bucket [Aws::S3::Bucket] The S3 bucket. This parameter is required.
      # @param key_prefix [String] The prefix for all S3 object keys. Defaults to
      #   `"patient_http/payloads/"`.
      # @raise [ArgumentError] If no bucket is provided.
      def initialize(bucket:, key_prefix: nil)
        raise ArgumentError, "S3 bucket is required" unless bucket

        @bucket = bucket
        @key_prefix = key_prefix || "patient_http/payloads/"
      end

      # Stores a serialized JSON string directly in S3.
      #
      # @param key [String] A unique key, which is appended to the key prefix.
      # @param json [String] The serialized JSON string.
      # @return [String] The key.
      def store_json(key, json)
        full_key = key_with_prefix(key)
        @bucket.object(full_key).put(body: json, content_type: "application/json")
        key
      end

      # Fetches data from S3.
      #
      # @param key [String] The key to fetch.
      # @return [Hash, nil] The stored data, or nil if the key is not found.
      def fetch(key)
        full_key = key_with_prefix(key)
        response = @bucket.object(full_key).get

        JSON.parse(response.body.read)
      rescue Aws::S3::Errors::NoSuchKey
        nil
      end

      # Deletes a payload from S3.
      #
      # This method is idempotent. It does not raise an error if the object does not
      # exist.
      #
      # @param key [String] The key to delete.
      # @return [Boolean] Always true.
      def delete(key)
        full_key = key_with_prefix(key)
        @bucket.object(full_key).delete
        true
      end

      # Checks whether a payload exists.
      #
      # @param key [String] The key to check.
      # @return [Boolean] Whether the payload exists.
      def exists?(key)
        full_key = key_with_prefix(key)
        @bucket.object(full_key).exists?
      end

      private

      def key_with_prefix(key)
        "#{@key_prefix}#{key}"
      end
    end
  end
end
