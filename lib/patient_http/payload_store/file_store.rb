# frozen_string_literal: true

require "fileutils"

module PatientHttp
  module PayloadStore
    # A payload store that keeps payloads as JSON files in a directory. Use it
    # only for development and tests, because hosts don't share the files. In
    # production, use another store.
    #
    # The store is thread-safe.
    #
    # @example Register a file store
    #   config.register_payload_store(:files, adapter: :file, directory: "/tmp/payloads")
    class FileStore < Base
      Base.register :file, self

      # @return [String] The directory for the payload files.
      attr_reader :directory

      # Creates a file store.
      #
      # @param directory [String] The directory for the payload files. The
      #   default is `Dir.tmpdir`. The directory is created if it doesn't exist.
      def initialize(directory: nil)
        @directory = directory || Dir.tmpdir
        @mutex = Mutex.new
        FileUtils.mkdir_p(@directory)
      end

      # Writes a JSON string to a file.
      #
      # @param key [String] The unique key. The file name is the key.
      # @param json [String] The serialized JSON.
      # @return [String] The key.
      def store_json(key, json)
        path = file_path(key)
        @mutex.synchronize do
          File.write(path, json)
        end
        key
      end

      # Fetches stored data.
      #
      # @param key [String] The key.
      # @return [Hash, nil] The parsed data, or `nil` if the key isn't found.
      def fetch(key)
        path = file_path(key)
        @mutex.synchronize do
          return nil unless File.exist?(path)

          JSON.parse(File.read(path))
        end
      end

      # Deletes stored data. Doesn't raise an error if the key doesn't exist.
      #
      # @param key [String] The key.
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

      # Returns whether a payload exists.
      #
      # @param key [String] The key.
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
