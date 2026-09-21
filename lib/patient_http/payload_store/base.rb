# frozen_string_literal: true

require "securerandom"

module PatientHttp
  module PayloadStore
    # Abstract base class for payload stores.
    #
    # Payload stores provide external storage for Request and Response objects
    # that exceed the configured size threshold. This keeps job arguments
    # small while allowing large payloads to be processed.
    #
    # Subclasses must implement the abstract methods: store, fetch, and delete.
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
    #     def store(key, data)
    #       @mutex.synchronize { @connection.set(key, JSON.generate(data)) }
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
        # Register a payload store adapter.
        #
        # @param name [Symbol] unique identifier for this adapter
        # @param klass [Class] the adapter class
        # @return [void]
        def register(name, klass)
          registry_mutex.synchronize do
            registry[name.to_sym] = klass
          end
        end

        # Look up a registered adapter by name.
        #
        # @param name [Symbol, String] the adapter name
        # @return [Class, nil] the adapter class or nil if not found
        def lookup(name)
          registry_mutex.synchronize do
            registry[name.to_sym]
          end
        end

        # Create a new store instance from a registered adapter.
        #
        # @param name [Symbol, String] the adapter name
        # @param options [Hash] options to pass to the adapter constructor
        # @return [Base] a new store instance
        # @raise [ArgumentError] if the adapter is not registered
        def create(name, **options)
          klass = lookup(name)
          raise ArgumentError, "Unknown payload store adapter: #{name.inspect}" unless klass

          klass.new(**options)
        end

        # List all registered adapter names.
        #
        # @return [Array<Symbol>] registered adapter names
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

      # Store data with the given key.
      #
      # @param key [String] unique key for this data
      # @param data [Hash] the data to store (serialized as JSON)
      # @return [String] the key
      def store(key, data)
        json = JSON.generate(data)
        store_json(key, json)
      end

      # Store pre-serialized JSON data with the given key.
      #
      # Subclasses that serialize in #store should override this to write
      # the string directly, avoiding double serialization.
      #
      # @param key [String] unique key for this data
      # @param json [String] pre-serialized JSON string
      # @return [String] the key
      # @raise [NotImplementedError] subclasses must implement this method
      def store_json(key, json)
        raise NotImplementedError, "#{self.class.name} must implement #store_json"
      end

      # Fetch data by key.
      #
      # @param key [String] the key to fetch
      # @return [Hash, nil] the stored data or nil if not found
      # @raise [NotImplementedError] subclasses must implement this method
      def fetch(key)
        raise NotImplementedError, "#{self.class.name} must implement #fetch"
      end

      # Delete data by key.
      #
      # This method should be idempotent—deleting a non-existent key
      # should not raise an error.
      #
      # @param key [String] the key to delete
      # @return [Boolean] true
      # @raise [NotImplementedError] subclasses must implement this method
      def delete(key)
        raise NotImplementedError, "#{self.class.name} must implement #delete"
      end

      # Generate a unique key for storing data.
      #
      # @return [String] a UUID key
      def generate_key
        SecureRandom.uuid
      end
    end
  end
end
