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
      end

      # @return [Class] The ActiveRecord model class used for storage
      attr_reader :model

      # Initialize a new ActiveRecord store.
      #
      # @param model [Class] ActiveRecord model class to use for storage.
      #   Defaults to PatientHttp::PayloadStore::ActiveRecordStore::Payload.
      #   Custom models must have: key (string PK), data (text), timestamps
      def initialize(model: nil)
        @model = model || Payload
      end

      # Store pre-serialized JSON string directly in the database.
      #
      # @param key [String] Unique key (used as primary key)
      # @param json [String] Pre-serialized JSON string
      # @return [String] The key
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
      # @param key [String] The key to fetch
      # @return [Hash, nil] The stored data or nil if not found
      def fetch(key)
        record = @model.find_by(key: key)
        return nil unless record

        JSON.parse(record.data)
      end

      # Delete a payload from the database.
      #
      # Idempotent - does not raise if record doesn't exist.
      #
      # @param key [String] The key to delete
      # @return [Boolean] true
      def delete(key)
        @model.where(key: key).delete_all
        true
      end

      # Check if a payload exists.
      #
      # @param key [String] The key to check
      # @return [Boolean] true if the payload exists
      def exists?(key)
        @model.exists?(key: key)
      end
    end
  end
end
