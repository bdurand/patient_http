# frozen_string_literal: true

require "spec_helper"

RSpec.describe "PatientHttp::PayloadStore::ActiveRecordStore", :active_record do
  before(:all) do
    skip "ActiveRecord not available for testing" unless ActiveRecordHelper.available?
  end

  let(:described_class) { PatientHttp::PayloadStore::ActiveRecordStore }
  let(:store) { described_class.new }

  describe ".register" do
    it "is registered as :active_record adapter" do
      described_class
      expect(PatientHttp::PayloadStore::Base.lookup(:active_record)).to eq(described_class)
    end
  end

  describe "#initialize" do
    it "accepts default settings" do
      store = described_class.new
      expect(store.model).to eq(PatientHttp::PayloadStore::ActiveRecordStore::Payload)
    end

    it "accepts custom model" do
      custom_model = Class.new(ActiveRecord::Base) do
        self.table_name = "patient_http_payloads"
        self.primary_key = "key"
      end
      store = described_class.new(model: custom_model)
      expect(store.model).to eq(custom_model)
    end
  end

  describe "#store" do
    it "stores data as JSON in database" do
      data = {"status" => 200, "body" => "test"}
      key = store.store("test-key", data)

      expect(key).to eq("test-key")
      record = PatientHttp::PayloadStore::ActiveRecordStore::Payload.find_by(key: "test-key")
      expect(JSON.parse(record.data)).to eq(data)
    end

    it "overwrites existing data" do
      store.store("test-key", {"version" => 1})
      store.store("test-key", {"version" => 2})

      fetched = store.fetch("test-key")
      expect(fetched["version"]).to eq(2)
    end
  end

  describe "#fetch" do
    it "retrieves stored data" do
      data = {"status" => 200, "headers" => {"content-type" => "application/json"}}
      store.store("test-key", data)

      fetched = store.fetch("test-key")
      expect(fetched).to eq(data)
    end

    it "returns nil for non-existent keys" do
      expect(store.fetch("nonexistent")).to be_nil
    end
  end

  describe "#delete" do
    it "removes stored data" do
      store.store("test-key", {"data" => "value"})
      expect(store.fetch("test-key")).not_to be_nil

      result = store.delete("test-key")
      expect(result).to be true
      expect(store.fetch("test-key")).to be_nil
    end

    it "is idempotent for non-existent keys" do
      expect(store.delete("nonexistent")).to be true
      expect(store.delete("nonexistent")).to be true
    end
  end

  describe "#exists?" do
    it "returns true for existing keys" do
      store.store("test-key", {"data" => "value"})
      expect(store.exists?("test-key")).to be true
    end

    it "returns false for non-existent keys" do
      expect(store.exists?("nonexistent")).to be false
    end
  end

  describe "thread safety" do
    it "handles concurrent access safely" do
      threads = 3.times.map do |i|
        Thread.new do
          key = "thread-#{i}"
          data = {"thread" => i, "data" => "x" * 1000}

          store.store(key, data)
          fetched = store.fetch(key)
          expect(fetched["thread"]).to eq(i)
          store.delete(key)
        end
      end

      threads.each(&:join)
    end
  end

  describe "round trip" do
    it "stores and retrieves complex data" do
      data = {
        "status" => 200,
        "headers" => {"content-type" => "application/json", "x-custom" => "value"},
        "body" => {"encoding" => "text", "value" => "large body " * 1000},
        "duration" => 0.5,
        "redirects" => ["http://old.url", "http://new.url"]
      }

      key = store.generate_key
      store.store(key, data)
      fetched = store.fetch(key)

      expect(fetched).to eq(data)
    end
  end

  describe ".older_than scope" do
    it "returns records older than specified time" do
      old_record = PatientHttp::PayloadStore::ActiveRecordStore::Payload.create!(key: "old", data: "{}", created_at: 2.days.ago)
      new_record = PatientHttp::PayloadStore::ActiveRecordStore::Payload.create!(key: "new", data: "{}", created_at: 1.hour.ago)

      results = PatientHttp::PayloadStore::ActiveRecordStore::Payload.older_than(1.day.ago)
      expect(results).to include(old_record)
      expect(results).not_to include(new_record)
    end
  end
end
