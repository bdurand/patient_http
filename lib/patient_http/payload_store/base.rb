# frozen_string_literal: true

require "securerandom"

module PatientHttp
  module PayloadStore
    # Abstract base class for payload stores.
    #
    # A payload store holds {Request} and {Response} objects that are larger than the
    # configured size threshold. This keeps the job arguments small and still lets you
    # process large payloads.
    #
    # @abstract Subclasses must implement `store`, `fetch`, and `delete`.
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
        # Registers a payload store adapter.
        #
        # @param name [Symbol] A unique identifier for this adapter.
        # @param klass [Class] The adapter class.
        # @return [void]
        def register(name, klass)
          registry_mutex.synchronize do
            registry[name.to_sym] = klass
          end
        end

        # Looks up a registered adapter by name.
        #
        # @param name [Symbol, String] The adapter name.
        # @return [Class, nil] The adapter class, or nil if the name is not found.
        def lookup(name)
          registry_mutex.synchronize do
            registry[name.to_sym]
          end
        end

        # Creates a new store from a registered adapter.
        #
        # @param name [Symbol, String] The adapter name.
        # @param options [Hash] The options to pass to the adapter constructor.
        # @return [Base] A new store.
        # @raise [ArgumentError] If the adapter is not registered.
        def create(name, **options)
          klass = lookup(name)
          raise ArgumentError, "Unknown payload store adapter: #{name.inspect}" unless klass

          klass.new(**options)
        end

        # Lists all registered adapter names.
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
      # @param key [String] A unique key for this data.
      # @param data [Hash] The data to store. It is serialized as JSON.
      # @return [String] The key.
      def store(key, data)
        json = JSON.generate(data)
        store_json(key, json)
      end

      # Stores data that is already serialized as JSON with the given key.
      #
      # A subclass that serializes the data in `store` must override this method to
      # write the string directly, which prevents double serialization.
      #
      # @param key [String] A unique key for this data.
      # @param json [String] The serialized JSON string.
      # @return [String] The key.
      # @raise [NotImplementedError] If the subclass does not implement this method.
      def store_json(key, json)
        raise NotImplementedError, "#{self.class.name} must implement #store_json"
      end

      # Fetches data by key.
      #
      # @param key [String] The key to fetch.
      # @return [Hash, nil] The stored data, or nil if the key is not found.
      # @raise [NotImplementedError] If the subclass does not implement this method.
      def fetch(key)
        raise NotImplementedError, "#{self.class.name} must implement #fetch"
      end

      # Deletes data by key.
      #
      # This method must be idempotent. Deleting a key that does not exist must not
      # raise an error.
      #
      # @param key [String] The key to delete.
      # @return [Boolean] Always true.
      # @raise [NotImplementedError] If the subclass does not implement this method.
      def delete(key)
        raise NotImplementedError, "#{self.class.name} must implement #delete"
      end

      # Generates a unique key for stored data.
      #
      # @return [String] A UUID key.
      def generate_key
        SecureRandom.uuid
      end
    end
  end
end
