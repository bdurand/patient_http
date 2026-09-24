# frozen_string_literal: true

require "fileutils"

module PatientHttp
  module PayloadStore
    # A file-based payload store for testing and development.
    #
    # This store saves payloads as JSON files in a directory. Use it only for local
    # development and testing. For production deployments, use the Redis, S3, or
    # ActiveRecord store.
    #
    # This store is thread-safe. It synchronizes access with a mutex.
    #
    # @example Configuration
    #   config.register_payload_store(:files, adapter: :file, directory: "/tmp/payloads")
    class FileStore < Base
      Base.register :file, self

      # @return [String] The directory where payload files are stored.
      attr_reader :directory

      # Creates a file store.
      #
      # @param directory [String] The directory for payload files. Defaults to
      #   `Dir.tmpdir`. The directory is created if it doesn't exist.
      def initialize(directory: nil)
        @directory = directory || Dir.tmpdir
        @mutex = Mutex.new
        FileUtils.mkdir_p(@directory)
      end

      # Writes a serialized JSON string to a file.
      #
      # @param key [String] A unique key. The key is the filename.
      # @param json [String] The serialized JSON string.
      # @return [String] The key.
      def store_json(key, json)
        path = file_path(key)
        @mutex.synchronize do
          File.write(path, json)
        end
        key
      end

      # Fetches data from a JSON file.
      #
      # @param key [String] The key to fetch.
      # @return [Hash, nil] The stored data, or `nil` if it isn't found.
      def fetch(key)
        path = file_path(key)
        @mutex.synchronize do
          return nil unless File.exist?(path)

          JSON.parse(File.read(path))
        end
      end

      # Deletes a payload file.
      #
      # This method is idempotent. It doesn't raise an error if the file doesn't exist.
      #
      # @param key [String] The key to delete.
      # @return [Boolean] `true`.
      def delete(key)
        path = file_path(key)
        @mutex.synchronize do
          File.delete(path) if File.exist?(path)
        end
        true
      rescue Errno::ENOENT
        true
      end

      # Returns `true` if a payload exists.
      #
      # @param key [String] The key to check.
      # @return [Boolean] `true` if the payload exists.
      def exists?(key)
        @mutex.synchronize do
          File.exist?(file_path(key))
        end
      end

      private

      def file_path(key)
        File.join(@directory, "#{key}.json")
      end
    end
  end
end
