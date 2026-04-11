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
        # @param name [Symbol] Unique identifier for this adapter
        # @param klass [Class] The adapter class
        # @return [void]
        def register(name, klass)
          registry_mutex.synchronize do
            registry[name.to_sym] = klass
          end
        end

        # Look up a registered adapter by name.
        #
        # @param name [Symbol, String] The adapter name
        # @return [Class, nil] The adapter class or nil if not found
        def lookup(name)
          registry_mutex.synchronize do
            registry[name.to_sym]
          end
        end

        # Create a new store instance from a registered adapter.
        #
        # @param name [Symbol, String] The adapter name
        # @param options [Hash] Options to pass to the adapter constructor
        # @return [Base] A new store instance
        # @raise [ArgumentError] If the adapter is not registered
        def create(name, **options)
          klass = lookup(name)
          raise ArgumentError, "Unknown payload store adapter: #{name.inspect}" unless klass

          klass.new(**options)
        end

        # List all registered adapter names.
        #
        # @return [Array<Symbol>] Registered adapter names
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
      # @param key [String] Unique key for this data
      # @param data [Hash] The data to store (will be serialized as JSON)
      # @return [String] The key
      def store(key, data)
        json = JSON.generate(data)
        store_json(key, json)
      end

      # Store pre-serialized JSON data with the given key.
      #
      # Subclasses that serialize in #store should override this to write
      # the string directly, avoiding double serialization.
      #
      # @param key [String] Unique key for this data
      # @param json [String] Pre-serialized JSON string
      # @return [String] The key
      # @raise [NotImplementedError] Subclasses must implement this method
      def store_json(key, json)
        raise NotImplementedError, "#{self.class.name} must implement #store_json"
      end

      # Fetch data by key.
      #
      # @param key [String] The key to fetch
      # @return [Hash, nil] The stored data or nil if not found
      # @raise [NotImplementedError] Subclasses must implement this method
      def fetch(key)
        raise NotImplementedError, "#{self.class.name} must implement #fetch"
      end

      # Delete data by key.
      #
      # This method should be idempotent - deleting a non-existent key
      # should not raise an error.
      #
      # @param key [String] The key to delete
      # @return [Boolean] true
      # @raise [NotImplementedError] Subclasses must implement this method
      def delete(key)
        raise NotImplementedError, "#{self.class.name} must implement #delete"
      end

      # Generate a unique key for storing data.
      #
      # @return [String] A UUID key
      def generate_key
        SecureRandom.uuid
      end
    end
  end
end
