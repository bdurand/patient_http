# frozen_string_literal: true

require_relative "base"

module PatientHttp
  module PayloadStore
    # ActiveRecord-based payload store for production deployments.
    #
    # Stores payloads as JSON in a database table. This store is recommended
    # when you need database-backed storage with transactional guarantees.
    #
    # Thread-safe: ActiveRecord handles connection pooling and thread safety.
    #
    # @example Configuration
    #   require "patient_http/payload_store/active_record_store"
    #   config.register_payload_store(:database, adapter: :active_record)
    #
    # @example With custom model
    #   config.register_payload_store(:database, adapter: :active_record,
    #     model: MyApp::PayloadRecord
    #   )
    class ActiveRecordStore < Base
      Base.register :active_record, self

      # ActiveRecord model for payload storage.
      #
      # Defined in this file to avoid loading ActiveRecord until explicitly required.
      # The table must be created using the migration provided by this gem.
      #
      # @example Install migrations in a Rails app
      #   rails patient_http:install:migrations
      #   rails db:migrate
      class Payload < ::ActiveRecord::Base
        self.table_name = "patient_http_payloads"
        self.primary_key = "key"

        scope :older_than, ->(time) { where(created_at: nil...time) }
      end

      # @return [Class] the ActiveRecord model class used for storage
      attr_reader :model

      # Initialize a new ActiveRecord store.
      #
      # @param model [Class] ActiveRecord model class to use for storage. It defaults to
      #   PatientHttp::PayloadStore::ActiveRecordStore::Payload. A custom model must have
      #   a key column (string primary key), a data column (text), and timestamps.
      def initialize(model: nil)
        @model = model || Payload
      end

      # Store pre-serialized JSON string directly in the database.
      #
      # @param key [String] unique key (used as primary key)
      # @param json [String] pre-serialized JSON string
      # @return [String] the key
      def store_json(key, json)
        now = Time.current

        @model.with_connection do
          @model.upsert(
            {key: key, data: json, created_at: now, updated_at: now},
            unique_by: :key,
            update_only: [:data, :updated_at]
          )
        end

        key
      end

      # Fetch data from the database.
      #
      # @param key [String] the key to fetch
      # @return [Hash, nil] the stored data or nil if not found
      def fetch(key)
        record = @model.find_by(key: key)
        return nil unless record

        JSON.parse(record.data)
      end

      # Delete a payload from the database.
      #
      # Idempotent—does not raise if record does not exist.
      #
      # @param key [String] the key to delete
      # @return [Boolean] true
      def delete(key)
        @model.where(key: key).delete_all
        true
      end

      # Check whether a payload exists.
      #
      # @param key [String] the key to check
      # @return [Boolean] true if the payload exists
      def exists?(key)
        @model.exists?(key: key)
      end
    end
  end
end
