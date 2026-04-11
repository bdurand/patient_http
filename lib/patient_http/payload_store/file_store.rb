# frozen_string_literal: true

require "fileutils"

module PatientHttp
  module PayloadStore
    # File-based payload store for testing and development.
    #
    # Stores payloads as JSON files in a directory. This store is intended
    # for local development and testing only - use Redis or S3 stores for
    # production deployments.
    #
    # Thread-safe through mutex synchronization.
    #
    # @example Configuration
    #   config.register_payload_store(:files, adapter: :file, directory: "/tmp/payloads")
    class FileStore < Base
      Base.register :file, self

      # @return [String] The directory where payload files are stored
      attr_reader :directory

      # Initialize a new file store.
      #
      # @param directory [String] Directory for storing payload files.
      #   Defaults to Dir.tmpdir. Will be created if it doesn't exist.
      def initialize(directory: nil)
        @directory = directory || Dir.tmpdir
        @mutex = Mutex.new
        FileUtils.mkdir_p(@directory)
      end

      # Store pre-serialized JSON string directly to a file.
      #
      # @param key [String] Unique key (used as filename)
      # @param json [String] Pre-serialized JSON string
      # @return [String] The key
      def store_json(key, json)
        path = file_path(key)
        @mutex.synchronize do
          File.write(path, json)
        end
        key
      end

      # Fetch data from a JSON file.
      #
      # @param key [String] The key to fetch
      # @return [Hash, nil] The stored data or nil if not found
      def fetch(key)
        path = file_path(key)
        @mutex.synchronize do
          return nil unless File.exist?(path)

          JSON.parse(File.read(path))
        end
      end

      # Delete a payload file.
      #
      # Idempotent - does not raise if file doesn't exist.
      #
      # @param key [String] The key to delete
      # @return [Boolean] true
      def delete(key)
        path = file_path(key)
        @mutex.synchronize do
          File.delete(path) if File.exist?(path)
        end
        true
      rescue Errno::ENOENT
        true
      end

      # Check if a payload exists.
      #
      # @param key [String] The key to check
      # @return [Boolean] true if the payload exists
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
