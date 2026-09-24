# frozen_string_literal: true

begin
  require "aws-sdk-s3"
rescue LoadError
  raise LoadError, "The aws-sdk-s3 gem is required to use S3Store. Add it to your Gemfile: gem 'aws-sdk-s3'"
end

module PatientHttp
  module PayloadStore
    # A payload store that keeps payloads as JSON objects in Amazon S3. Use it
    # in production when payloads need durable storage that several processes
    # and hosts share.
    #
    # Requires the `aws-sdk-s3` gem. The S3 client is responsible for thread
    # safety.
    #
    # @example Register an S3 store
    #   s3 = Aws::S3::Resource.new
    #   bucket = s3.bucket("my-payloads-bucket")
    #   config.register_payload_store(:s3, adapter: :s3, bucket: bucket)
    class S3Store < Base
      Base.register :s3, self

      # @return [String] The prefix for the keys of all stored payloads.
      attr_reader :key_prefix

      # Creates an S3 store.
      #
      # @param bucket [Aws::S3::Bucket] The S3 bucket.
      # @param key_prefix [String] The prefix for all S3 object keys.
      # @raise [ArgumentError] If the bucket is missing.
      def initialize(bucket:, key_prefix: nil)
        raise ArgumentError, "S3 bucket is required" unless bucket

        @bucket = bucket
        @key_prefix = key_prefix || "patient_http/payloads/"
      end

      # Stores a JSON string in S3.
      #
      # @param key [String] The unique key. The object key is the key prefix
      #   and this key.
      # @param json [String] The serialized JSON.
      # @return [String] The key.
      def store_json(key, json)
        full_key = key_with_prefix(key)
        @bucket.object(full_key).put(body: json, content_type: "application/json")
        key
      end

      # Fetches stored data.
      #
      # @param key [String] The key.
      # @return [Hash, nil] The parsed data, or `nil` if the key isn't found.
      def fetch(key)
        full_key = key_with_prefix(key)
        response = @bucket.object(full_key).get

        JSON.parse(response.body.read)
      rescue Aws::S3::Errors::NoSuchKey
        nil
      end

      # Deletes stored data. Doesn't raise an error if the key doesn't exist.
      #
      # @param key [String] The key.
      # @return [Boolean] `true`.
      def delete(key)
        full_key = key_with_prefix(key)
        @bucket.object(full_key).delete
        true
      end

      # Returns whether a payload exists.
      #
      # @param key [String] The key.
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
