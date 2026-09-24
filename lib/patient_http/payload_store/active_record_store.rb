# frozen_string_literal: true

require_relative "base"

module PatientHttp
  module PayloadStore
    # A payload store backed by ActiveRecord, for production deployments.
    #
    # This store saves payloads as JSON in a database table. Use it when you need
    # database-backed storage with transactional guarantees.
    #
    # This store is thread-safe. ActiveRecord handles connection pooling and
    # thread safety.
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

      # The ActiveRecord model for payload storage.
      #
      # The model is defined in this file so that ActiveRecord loads only when you
      # require this file. Create the table with the migration that this gem provides.
      #
      # @example Install migrations in a Rails app
      #   rails patient_http:install:migrations
      #   rails db:migrate
      class Payload < ::ActiveRecord::Base
        self.table_name = "patient_http_payloads"
        self.primary_key = "key"

        scope :older_than, ->(time) { where(created_at: nil...time) }
      end

      # @return [Class] The ActiveRecord model class used for storage.
      attr_reader :model

      # Creates an ActiveRecord store.
      #
      # @param model [Class] The ActiveRecord model class for storage. Defaults to
      #   {PatientHttp::PayloadStore::ActiveRecordStore::Payload}. A custom model must have
      #   a `key` string primary key, a `data` text column, and timestamps.
      def initialize(model: nil)
        @model = model || Payload
      end

      # Stores a serialized JSON string in the database.
      #
      # @param key [String] A unique key. The key is the primary key.
      # @param json [String] The serialized JSON string.
      # @return [String] The key.
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

      # Fetches data from the database.
      #
      # @param key [String] The key to fetch.
      # @return [Hash, nil] The stored data, or `nil` if it isn't found.
      def fetch(key)
        record = @model.find_by(key: key)
        return nil unless record

        JSON.parse(record.data)
      end

      # Deletes a payload from the database.
      #
      # This method is idempotent. It doesn't raise an error if the record doesn't exist.
      #
      # @param key [String] The key to delete.
      # @return [Boolean] `true`.
      def delete(key)
        @model.where(key: key).delete_all
        true
      end

      # Returns `true` if a payload exists.
      #
      # @param key [String] The key to check.
      # @return [Boolean] `true` if the payload exists.
      def exists?(key)
        @model.exists?(key: key)
      end
    end
  end
end
