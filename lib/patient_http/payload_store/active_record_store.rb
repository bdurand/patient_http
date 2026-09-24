# frozen_string_literal: true

require_relative "base"

module PatientHttp
  module PayloadStore
    # A payload store that keeps payloads as JSON in a database table. Use it in
    # production when you want payloads in your database.
    #
    # Active Record is responsible for connection pooling and thread safety.
    # The store requires the `patient_http_payloads` table.
    #
    # @example Register an Active Record store
    #   config.register_payload_store(:database, adapter: :active_record)
    #
    # @example Register a store with a custom model
    #   config.register_payload_store(:database, adapter: :active_record,
    #     model: MyApp::PayloadRecord
    #   )
    class ActiveRecordStore < Base
      Base.register :active_record, self

      # The default Active Record model for stored payloads.
      #
      # The model is defined in this file, so Active Record loads only when
      # the store is used. Create the table with the migration from this gem.
      #
      # @example Install the migration in a Rails app
      #   # Add require "patient_http/rails/engine" to an initializer.
      #   bin/rails patient_http:install:migrations
      #   bin/rails db:migrate
      class Payload < ::ActiveRecord::Base
        self.table_name = "patient_http_payloads"
        self.primary_key = "key"

        scope :older_than, ->(time) { where(created_at: nil...time) }
      end

      # @return [Class] The Active Record model for stored payloads.
      attr_reader :model

      # Creates an Active Record store.
      #
      # @param model [Class, nil] The Active Record model. If `nil`, {Payload}
      #   applies. A custom model must have a `key` string primary key, a `data`
      #   text column, and timestamps.
      def initialize(model: nil)
        @model = model || Payload
      end

      # Stores a JSON string in the database.
      #
      # @param key [String] The unique key. The primary key is this key.
      # @param json [String] The serialized JSON.
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

      # Fetches stored data.
      #
      # @param key [String] The key.
      # @return [Hash, nil] The parsed data, or `nil` if the key isn't found.
      def fetch(key)
        record = @model.find_by(key: key)
        return nil unless record

        JSON.parse(record.data)
      end

      # Deletes stored data. Doesn't raise an error if the key doesn't exist.
      #
      # @param key [String] The key.
      # @return [Boolean] `true`.
      def delete(key)
        @model.where(key: key).delete_all
        true
      end

      # Returns whether a payload exists.
      #
      # @param key [String] The key.
      # @return [Boolean] `true` if the payload exists.
      def exists?(key)
        @model.exists?(key: key)
      end
    end
  end
end
