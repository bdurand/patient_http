# frozen_string_literal: true

module PatientHttp
  # Stores, fetches, and deletes large payloads in external storage.
  #
  # This class has no knowledge of the models that it stores ({Request}, {Response},
  # and {Error}).
  #
  # @example Storing a large payload
  #   external_storage = ExternalStorage.new(config)
  #   data = response.as_json
  #   stored_data = external_storage.store(data)
  #
  # @example Fetching and deleting
  #   if ExternalStorage.storage_ref?(data)
  #     external_storage = ExternalStorage.new(config)
  #     original_data = external_storage.fetch(data)
  #     response = Response.load(original_data)
  #     external_storage.delete(data)
  #   end
  class ExternalStorage
    # Key that marks an external storage reference in serialized JSON.
    REFERENCE_KEY = "$ref"

    # Raised when no payload store is configured, or when a reference names a store
    # that is not registered.
    class PayloadStoreNotFoundError < StandardError; end

    # Raised when a reference names a payload that the store does not hold.
    class PayloadNotFoundError < StandardError; end

    class << self
      # Checks whether a hash is a storage reference.
      #
      # @param data [Hash, Object] The data to check.
      # @return [Boolean] Whether the data is a reference to external storage.
      def storage_ref?(data)
        data.is_a?(Hash) && data.key?(REFERENCE_KEY)
      end
    end

    # @return [Configuration] The pool configuration.
    attr_reader :config

    # Initializes a new ExternalStorage.
    #
    # @param config [Configuration] The pool configuration.
    def initialize(config)
      @config = config
    end

    # Checks whether a hash is a storage reference.
    #
    # @param data [Hash, Object] The data to check.
    # @return [Boolean] Whether the data is a reference to external storage.
    def storage_ref?(data)
      self.class.storage_ref?(data)
    end

    # Checks whether external storage is enabled, that is, whether a payload store is
    # configured.
    #
    # @return [Boolean] Whether external storage is configured.
    def enabled?
      !!config.payload_store
    end

    # Stores a hash externally if it is larger than the configured threshold.
    #
    # If the hash is smaller than the threshold, the original hash is returned
    # unchanged.
    #
    # @param data [Hash] The hash to store.
    # @param max_size [Integer, nil] An optional payload size threshold, in bytes. The
    #   JSON payload is stored externally only if it is larger than this size. If it
    #   is not larger, the original hash is returned. When nil, which is the default,
    #   the payload is always stored externally.
    # @return [Hash] The reference hash if the payload is stored, or the original hash
    #   if it is not.
    # @raise [PayloadStoreNotFoundError] If no payload store is configured.
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

    # Fetches a hash from external storage.
    #
    # @param data [Hash] The reference hash that holds the storage location.
    # @return [Hash] The original hash from storage.
    # @raise [PayloadStoreNotFoundError] If the store is not registered.
    # @raise [PayloadNotFoundError] If the stored payload is not found.
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

    # Deletes a payload from external storage.
    #
    # This method is idempotent. You can call it on a hash that is not a reference, on
    # a payload that is already deleted, or on nil.
    #
    # @param data [Hash, nil] The reference hash. A regular hash is ignored.
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
