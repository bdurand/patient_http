# frozen_string_literal: true

class CreatePatientHttpPayloads < ActiveRecord::Migration[7.0]
  def change
    create_table :patient_http_payloads, id: false do |t|
      t.string :key, null: false, limit: 36
      t.text :data, null: false

      t.timestamps
    end

    add_index :patient_http_payloads, :key, unique: true
    add_index :patient_http_payloads, :created_at
  end
end
