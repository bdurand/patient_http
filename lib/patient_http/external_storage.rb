# frozen_string_literal: true

module PatientHttp
  # Stores large payloads in the registered payload store, and replaces them
  # with a reference.
  #
  # A reference has the form `{"$ref" => {"store" => name, "key" => key}}`. This
  # class works with any JSON-compatible hash, such as a serialized {Request},
  # {Response}, or {Error}.
  #
  # @example Store a payload
  #   external_storage = ExternalStorage.new(config)
  #   data = response.as_json
  #   stored_data = external_storage.store(data)
  #
  # @example Fetch and delete a payload
  #   if ExternalStorage.storage_ref?(data)
  #     external_storage = ExternalStorage.new(config)
  #     original_data = external_storage.fetch(data)
  #     response = Response.load(original_data)
  #     external_storage.delete(data)
  #   end
  class ExternalStorage
    # The key that identifies a storage reference in serialized JSON.
    REFERENCE_KEY = "$ref"

    # Raised when no payload store is registered, or when a reference names a
    # store that isn't registered.
    class PayloadStoreNotFoundError < StandardError; end

    # Raised when a referenced payload isn't in the store.
    class PayloadNotFoundError < StandardError; end

    class << self
      # Returns whether data is a storage reference.
      #
      # @param data [Hash, Object] The data to check.
      # @return [Boolean] `true` if the data is a storage reference.
      def storage_ref?(data)
        data.is_a?(Hash) && data.key?(REFERENCE_KEY)
      end
    end

    # @return [Configuration] The configuration that has the payload stores.
    attr_reader :config

    # Creates an external storage object.
    #
    # @param config [Configuration] The configuration that has the payload
    #   stores.
    def initialize(config)
      @config = config
    end

    # Returns whether data is a storage reference.
    #
    # @param data [Hash, Object] The data to check.
    # @return [Boolean] `true` if the data is a storage reference.
    def storage_ref?(data)
      self.class.storage_ref?(data)
    end

    # Returns whether a payload store is registered.
    #
    # @return [Boolean] `true` if a payload store is registered.
    def enabled?
      !!config.payload_store
    end

    # Stores a hash in the default payload store, and returns a reference to
    # it.
    #
    # @param data [Hash] The hash to store.
    # @param max_size [Integer, nil] The size in bytes above which the hash is
    #   stored. If the JSON is this size or smaller, the original hash is
    #   returned. If `nil`, the hash is always stored.
    # @return [Hash] The reference, or the original hash if it wasn't stored.
    # @raise [PayloadStoreNotFoundError] If no payload store is registered.
    def store(data, max_size: nil)
      store = config.payload_store
      raise PayloadStoreNotFoundError.new("No payload store configured") unless store

      json = JSON.generate(data)
      return data if max_size && json.bytesize <= max_size

      key = store.generate_key
      store.store_json(key, json)

      {
        REFERENCE_KEY => {
          "store" => config.default_payload_store_name.to_s,
          "key" => key
        }
      }
    end

    # Fetches a stored hash.
    #
    # @param data [Hash] The reference.
    # @return [Hash] The stored hash.
    # @raise [ArgumentError] If the data isn't a storage reference.
    # @raise [PayloadStoreNotFoundError] If the store isn't registered.
    # @raise [PayloadNotFoundError] If the payload isn't in the store.
    def fetch(data)
      raise ArgumentError.new("Not a storage reference") unless self.class.storage_ref?(data)

      ref = data[REFERENCE_KEY]
      store_name = ref["store"].to_sym
      key = ref["key"]

      store = config.payload_store(store_name)
      raise PayloadStoreNotFoundError.new("Payload store '#{store_name}' not registered") unless store

      stored_data = store.fetch(key)
      raise PayloadNotFoundError.new("Stored payload not found: #{store_name}/#{key}") unless stored_data

      stored_data
    end

    # Deletes a stored payload.
    #
    # This method is idempotent. You can call it with `nil`, with a hash that
    # isn't a reference, or with a reference to a deleted payload.
    #
    # @param data [Hash, nil] The reference. Other values are ignored.
    # @return [void]
    def delete(data)
      return unless data && self.class.storage_ref?(data)

      ref = data[REFERENCE_KEY]
      store_name = ref["store"].to_sym
      key = ref["key"]

      store = config.payload_store(store_name)
      store&.delete(key)
    end
  end
end
