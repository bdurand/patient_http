# frozen_string_literal: true

begin
  require "aws-sdk-s3"
rescue LoadError
  raise LoadError, "The aws-sdk-s3 gem is required to use S3Store. Add it to your Gemfile: gem 'aws-sdk-s3'"
end

module PatientHttp
  module PayloadStore
    # S3-based payload store for production deployments.
    #
    # Stores payloads as JSON objects in S3. This store is recommended
    # for production environments where payloads need durable storage
    # and can be shared across multiple processes/instances.
    #
    # Thread-safe: S3 clients handle their own thread safety.
    #
    # @example Configuration with S3 bucket
    #   s3 = Aws::S3::Resource.new
    #   bucket = s3.bucket("my-payloads-bucket")
    #   config.register_payload_store(:s3, adapter: :s3, bucket: bucket)
    class S3Store < Base
      Base.register :s3, self

      # @return [String] The key prefix used for all stored payloads
      attr_reader :key_prefix

      # Initialize a new S3 store.
      #
      # @param bucket [Aws::S3::Bucket] S3 Bucket object. Required.
      # @param key_prefix [String] Prefix for all S3 object keys.
      #   Defaults to "patient_http/payloads/"
      # @raise [ArgumentError] If bucket is not provided
      def initialize(bucket:, key_prefix: nil)
        raise ArgumentError, "S3 bucket is required" unless bucket

        @bucket = bucket
        @key_prefix = key_prefix || "patient_http/payloads/"
      end

      # Store pre-serialized JSON string directly in S3.
      #
      # @param key [String] Unique key (appended to key_prefix)
      # @param json [String] Pre-serialized JSON string
      # @return [String] The key
      def store_json(key, json)
        full_key = key_with_prefix(key)
        @bucket.object(full_key).put(body: json, content_type: "application/json")
        key
      end

      # Fetch data from S3.
      #
      # @param key [String] The key to fetch
      # @return [Hash, nil] The stored data or nil if not found
      def fetch(key)
        full_key = key_with_prefix(key)
        response = @bucket.object(full_key).get

        JSON.parse(response.body.read)
      rescue Aws::S3::Errors::NoSuchKey
        nil
      end

      # Delete a payload from S3.
      #
      # Idempotent - does not raise if object doesn't exist.
      #
      # @param key [String] The key to delete
      # @return [Boolean] true
      def delete(key)
        full_key = key_with_prefix(key)
        @bucket.object(full_key).delete
        true
      end

      # Check if a payload exists.
      #
      # @param key [String] The key to check
      # @return [Boolean] true if the payload exists
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
