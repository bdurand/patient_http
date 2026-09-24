# frozen_string_literal: true

begin
  require "aws-sdk-s3"
rescue LoadError
  raise LoadError, "The aws-sdk-s3 gem is required to use S3Store. Add it to your Gemfile: gem 'aws-sdk-s3'"
end

module PatientHttp
  module PayloadStore
    # An S3-based payload store for production deployments.
    #
    # This store saves payloads as JSON objects in S3. Use it in production
    # environments where payloads need durable storage that multiple processes and
    # instances share.
    #
    # This store is thread-safe. S3 clients handle their own thread safety.
    #
    # @example Configuration with S3 bucket
    #   s3 = Aws::S3::Resource.new
    #   bucket = s3.bucket("my-payloads-bucket")
    #   config.register_payload_store(:s3, adapter: :s3, bucket: bucket)
    class S3Store < Base
      Base.register :s3, self

      # @return [String] The key prefix used for all stored payloads.
      attr_reader :key_prefix

      # Creates an S3 store.
      #
      # @param bucket [Aws::S3::Bucket] The S3 bucket. Required.
      # @param key_prefix [String] The prefix for all S3 object keys. Defaults to
      #   `"patient_http/payloads/"`.
      # @raise [ArgumentError] If you don't provide a bucket.
      def initialize(bucket:, key_prefix: nil)
        raise ArgumentError, "S3 bucket is required" unless bucket

        @bucket = bucket
        @key_prefix = key_prefix || "patient_http/payloads/"
      end

      # Stores a serialized JSON string in S3.
      #
      # @param key [String] A unique key. The key is appended to `key_prefix`.
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
      # @return [Hash, nil] The stored data, or `nil` if it isn't found.
      def fetch(key)
        full_key = key_with_prefix(key)
        response = @bucket.object(full_key).get

        JSON.parse(response.body.read)
      rescue Aws::S3::Errors::NoSuchKey
        nil
      end

      # Deletes a payload from S3.
      #
      # This method is idempotent. It doesn't raise an error if the object doesn't exist.
      #
      # @param key [String] The key to delete.
      # @return [Boolean] `true`.
      def delete(key)
        full_key = key_with_prefix(key)
        @bucket.object(full_key).delete
        true
      end

      # Returns `true` if a payload exists.
      #
      # @param key [String] The key to check.
      # @return [Boolean] `true` if the payload exists.
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
