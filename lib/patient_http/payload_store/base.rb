# frozen_string_literal: true

require "securerandom"

module PatientHttp
  module PayloadStore
    # The abstract base class for payload stores.
    #
    # Payload stores provide external storage for {Request} and {Response} objects
    # that exceed the size threshold. Job arguments stay small, and large payloads
    # can still be processed.
    #
    # Subclasses must implement `store_json`, `fetch`, and `delete`.
    #
    # @example Creating a custom store
    #   class MyStore < PatientHttp::PayloadStore::Base
    #     register :my_store, self
    #
    #     def initialize(connection:)
    #       @connection = connection
    #       @mutex = Mutex.new
    #     end
    #
    #     def store_json(key, json)
    #       @mutex.synchronize { @connection.set(key, json) }
    #       key
    #     end
    #
    #     def fetch(key)
    #       @mutex.synchronize { JSON.parse(@connection.get(key)) }
    #     rescue KeyNotFoundError
    #       nil
    #     end
    #
    #     def delete(key)
    #       @mutex.synchronize { @connection.delete(key) }
    #       true
    #     rescue KeyNotFoundError
    #       true
    #     end
    #   end
    class Base
      class << self
        # Registers a payload store adapter.
        #
        # @param name [Symbol] A unique identifier for the adapter.
        # @param klass [Class] The adapter class.
        # @return [void]
        def register(name, klass)
          registry_mutex.synchronize do
            registry[name.to_sym] = klass
          end
        end

        # Returns a registered adapter by name.
        #
        # @param name [Symbol, String] The adapter name.
        # @return [Class, nil] The adapter class, or `nil` if it isn't found.
        def lookup(name)
          registry_mutex.synchronize do
            registry[name.to_sym]
          end
        end

        # Creates a store from a registered adapter.
        #
        # @param name [Symbol, String] The adapter name.
        # @param options [Hash] The options to pass to the adapter constructor.
        # @return [Base] A new store instance.
        # @raise [ArgumentError] If the adapter is not registered.
        def create(name, **options)
          klass = lookup(name)
          raise ArgumentError, "Unknown payload store adapter: #{name.inspect}" unless klass

          klass.new(**options)
        end

        # Returns the names of all registered adapters.
        #
        # @return [Array<Symbol>] The registered adapter names.
        def registered_adapters
          registry_mutex.synchronize do
            registry.keys
          end
        end

        private

        def registry
          @registry ||= {}
        end

        def registry_mutex
          @registry_mutex ||= Mutex.new
        end
      end

      # Stores data with the given key.
      #
      # @param key [String] A unique key for the data.
      # @param data [Hash] The data to store. The data is serialized as JSON.
      # @return [String] The key.
      def store(key, data)
        json = JSON.generate(data)
        store_json(key, json)
      end

      # Stores serialized JSON data with the given key.
      #
      # Subclasses must implement this method to write the string directly, so data
      # isn't serialized twice.
      #
      # @param key [String] A unique key for the data.
      # @param json [String] The serialized JSON string.
      # @return [String] The key.
      # @raise [NotImplementedError] Subclasses must implement this method.
      def store_json(key, json)
        raise NotImplementedError, "#{self.class.name} must implement #store_json"
      end

      # Fetches data by key.
      #
      # @param key [String] The key to fetch.
      # @return [Hash, nil] The stored data, or `nil` if it isn't found.
      # @raise [NotImplementedError] Subclasses must implement this method.
      def fetch(key)
        raise NotImplementedError, "#{self.class.name} must implement #fetch"
      end

      # Deletes data by key.
      #
      # This method must be idempotent. Deleting a key that doesn't exist must not
      # raise an error.
      #
      # @param key [String] The key to delete.
      # @return [Boolean] `true`.
      # @raise [NotImplementedError] Subclasses must implement this method.
      def delete(key)
        raise NotImplementedError, "#{self.class.name} must implement #delete"
      end

      # Generates a unique key for storing data.
      #
      # @return [String] A UUID key.
      def generate_key
        SecureRandom.uuid
      end
    end
  end
end
