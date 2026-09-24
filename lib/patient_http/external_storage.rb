# frozen_string_literal: true

module PatientHttp
  # Stores, fetches, and deletes large payloads in external storage.
  #
  # This class doesn't depend on the models it stores, such as {Request},
  # {Response}, and {Error}.
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
    # The key that marks an external storage reference in serialized JSON.
    REFERENCE_KEY = "$ref"

    # Raised when no payload store is configured, or a reference names a store that
    # isn't registered.
    class PayloadStoreNotFoundError < StandardError; end

    # Raised when a stored payload isn't found.
    class PayloadNotFoundError < StandardError; end

    class << self
      # Returns `true` if a hash is a storage reference.
      #
      # @param data [Hash, Object] The data to check.
      # @return [Boolean] `true` if this is a reference to external storage.
      def storage_ref?(data)
        data.is_a?(Hash) && data.key?(REFERENCE_KEY)
      end
    end

    # @return [Configuration] The pool configuration.
    attr_reader :config

    # Creates an external storage object.
    #
    # @param config [Configuration] The pool configuration.
    def initialize(config)
      @config = config
    end

    # Returns `true` if a hash is a storage reference.
    #
    # @param data [Hash, Object] The data to check.
    # @return [Boolean] `true` if this is a reference to external storage.
    def storage_ref?(data)
      self.class.storage_ref?(data)
    end

    # Returns `true` if external storage is enabled, which means a payload store is
    # configured.
    #
    # @return [Boolean] `true` if external storage is configured.
    def enabled?
      !!config.payload_store
    end

    # Stores a hash externally if it exceeds the size threshold.
    #
    # If the hash is below the threshold, this method returns the original hash
    # unchanged.
    #
    # @param data [Hash] The hash to store.
    # @param max_size [Integer, nil] The size threshold, in bytes. The payload is stored
    #   externally only if its JSON exceeds this size. Otherwise, the original hash is
    #   returned. If `nil`, the payload is always stored externally. Defaults to `nil`.
    # @return [Hash] A reference hash if the payload was stored, or the original hash.
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
    # @param data [Hash] The reference hash with the storage location.
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
    # This method is idempotent. You can call it on hashes that aren't references,
    # on payloads that are already deleted, and on `nil`.
    #
    # @param data [Hash, nil] The reference hash. Other hashes are ignored.
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
