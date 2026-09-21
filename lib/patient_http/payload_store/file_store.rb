# frozen_string_literal: true

require "fileutils"

module PatientHttp
  module PayloadStore
    # Payload store for testing and development that uses local files.
    #
    # This store holds payloads as JSON files in a directory. Use it only for local
    # development and testing. For production deployments, use the Redis store or the
    # S3 store.
    #
    # This store is thread-safe through mutex synchronization.
    #
    # @example Configuration
    #   config.register_payload_store(:files, adapter: :file, directory: "/tmp/payloads")
    class FileStore < Base
      Base.register :file, self

      # @return [String] The directory that holds the payload files.
      attr_reader :directory

      # Initializes a new file store.
      #
      # @param directory [String] The directory that holds the payload files. Defaults
      #   to `Dir.tmpdir`. The directory is created if it does not exist.
      def initialize(directory: nil)
        @directory = directory || Dir.tmpdir
        @mutex = Mutex.new
        FileUtils.mkdir_p(@directory)
      end

      # Stores a serialized JSON string directly in a file.
      #
      # @param key [String] A unique key, which is used as the file name.
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
      # @return [Hash, nil] The stored data, or nil if the key is not found.
      def fetch(key)
        path = file_path(key)
        @mutex.synchronize do
          return nil unless File.exist?(path)

          JSON.parse(File.read(path))
        end
      end

      # Deletes a payload file.
      #
      # This method is idempotent. It does not raise an error if the file does not
      # exist.
      #
      # @param key [String] The key to delete.
      # @return [Boolean] Always true.
      def delete(key)
        path = file_path(key)
        @mutex.synchronize do
          File.delete(path) if File.exist?(path)
        end
        true
      rescue Errno::ENOENT
        true
      end

      # Checks whether a payload exists.
      #
      # @param key [String] The key to check.
      # @return [Boolean] Whether the payload exists.
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
