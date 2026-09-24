# frozen_string_literal: true

require "securerandom"

module PatientHttp
  module PayloadStore
    # The abstract base class for payload stores.
    #
    # A payload store holds serialized payloads that are larger than
    # `payload_store_threshold`, so that job arguments stay small.
    #
    # Subclasses must implement {#store_json}, {#fetch}, and {#delete}, and be
    # thread-safe.
    #
    # @example Create a custom store
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
        # @param name [Symbol] The unique adapter name.
        # @param klass [Class] The adapter class.
        # @return [void]
        def register(name, klass)
          registry_mutex.synchronize do
            registry[name.to_sym] = klass
          end
        end

        # Returns a registered adapter class.
        #
        # @param name [Symbol, String] The adapter name.
        # @return [Class, nil] The adapter class, or `nil` if it isn't registered.
        def lookup(name)
          registry_mutex.synchronize do
            registry[name.to_sym]
          end
        end

        # Creates a store from a registered adapter.
        #
        # @param name [Symbol, String] The adapter name.
        # @param options [Hash] The options for the adapter constructor.
        # @return [Base] The store.
        # @raise [ArgumentError] If the adapter isn't registered.
        def create(name, **options)
          klass = lookup(name)
          raise ArgumentError, "Unknown payload store adapter: #{name.inspect}" unless klass

          klass.new(**options)
        end

        # Returns the names of all registered adapters.
        #
        # @return [Array<Symbol>] The adapter names.
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

      # Stores a hash as JSON. This method calls {#store_json}.
      #
      # @param key [String] The unique key.
      # @param data [Hash] The data to store.
      # @return [String] The key.
      def store(key, data)
        json = JSON.generate(data)
        store_json(key, json)
      end

      # Stores a JSON string. {ExternalStorage} calls this method, so
      # subclasses must implement it.
      #
      # @param key [String] The unique key.
      # @param json [String] The serialized JSON.
      # @return [String] The key.
      # @raise [NotImplementedError] If the subclass doesn't implement it.
      def store_json(key, json)
        raise NotImplementedError, "#{self.class.name} must implement #store_json"
      end

      # Fetches stored data.
      #
      # @param key [String] The key.
      # @return [Hash, nil] The parsed data, or `nil` if the key isn't found.
      # @raise [NotImplementedError] If the subclass doesn't implement it.
      def fetch(key)
        raise NotImplementedError, "#{self.class.name} must implement #fetch"
      end

      # Deletes stored data. The method must be idempotent: deleting a key that
      # doesn't exist must not raise an error.
      #
      # @param key [String] The key.
      # @return [Boolean] `true`.
      # @raise [NotImplementedError] If the subclass doesn't implement it.
      def delete(key)
        raise NotImplementedError, "#{self.class.name} must implement #delete"
      end

      # Generates a unique key.
      #
      # @return [String] A UUID.
      def generate_key
        SecureRandom.uuid
      end
    end
  end
end
