# frozen_string_literal: true

module PatientHttp
  # Handles external storage of large payloads.
  #
  # This class provides methods for storing, fetching, and deleting
  # payloads from external storage. It is decoupled from the models
  # being stored (Request, Response, Error).
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
    # Key used in serialized JSON to indicate an external storage reference
    REFERENCE_KEY = "$ref"

    class PayloadStoreNotFoundError < StandardError; end
    class PayloadNotFoundError < StandardError; end

    class << self
      # Check if a hash is a storage reference.
      #
      # @param data [Hash, Object] Data to check
      # @return [Boolean] true if this is a reference to external storage
      def storage_ref?(data)
        data.is_a?(Hash) && data.key?(REFERENCE_KEY)
      end
    end

    # @return [Configuration] the pool configuration
    attr_reader :config

    # Create a new ExternalStorage instance.
    #
    # @param config [Configuration] the pool configuration
    def initialize(config)
      @config = config
    end

    # Check if a hash is a storage reference.
    #
    # @param data [Hash, Object] Data to check
    # @return [Boolean] true if this is a reference to external storage
    def storage_ref?(data)
      self.class.storage_ref?(data)
    end

    # Check if external storage is enabled (i.e. a payload store is configured).
    #
    # @return [Boolean] true if external storage is configured
    def enabled?
      !!config.payload_store
    end

    # Store a hash externally if it exceeds the configured threshold.
    #
    # If no payload store is configured, or if the hash is below the
    # threshold, the original hash is returned unchanged.
    #
    # @param data [Hash] Hash to potentially store
    # @param max_size [Integer, nil] Optional payload size threshold in bytes.
    #   The JSON payload will only be stored externally if it exceeds this size.
    #   If the JSON payload does not exceed the threshold, the original hash is returned.
    #   When nil (the default), the payload is always stored externally.
    # @return [Hash] Reference hash if stored, original hash if not
    # @raise [PayloadStoreNotFoundError] If no payload store is configured
    def store(data, max_size: nil)
      store = config.payload_store
      raise PayloadStoreNotFoundError.new("No payload store configured") unless store

      json_size = data.to_json.bytesize
      return data if max_size && json_size <= max_size

      key = store.generate_key
      store.store(key, data)

      {
        REFERENCE_KEY => {
          "store" => config.default_payload_store_name.to_s,
          "key" => key
        }
      }
    end

    # Fetch a hash from external storage.
    #
    # @param data [Hash] Reference hash containing storage location
    # @return [Hash] Original hash from storage
    # @raise [PayloadStoreNotFoundError] If the store is not registered
    # @raise [PayloadNotFoundError] If the stored payload is not found
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

    # Delete payload from external storage.
    #
    # This method is idempotent - it's safe to call on non-reference hashes,
    # already-deleted payloads, or nil values.
    #
    # @param data [Hash, nil] Reference hash (or regular hash, which is ignored)
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
