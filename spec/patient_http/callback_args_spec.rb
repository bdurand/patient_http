# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::CallbackArgs do
  describe "#initialize" do
    it "accepts nil and creates an empty args object" do
      args = described_class.new(nil)
      expect(args).to be_empty
      expect(args.size).to eq(0)
    end

    it "accepts a hash" do
      args = described_class.new({user_id: 123, name: "test"})
      expect(args[:user_id]).to eq(123)
      expect(args[:name]).to eq("test")
    end

    it "accepts an object that responds to to_h" do
      obj = double(to_h: {foo: "bar"})
      args = described_class.new(obj)
      expect(args[:foo]).to eq("bar")
    end

    it "converts keys to strings internally" do
      args = described_class.new({user_id: 123})
      expect(args.keys).to eq(["user_id"])
    end

    it "raises ArgumentError if object doesn't respond to to_h" do
      expect do
        described_class.new("not a hash")
      end.to raise_error(ArgumentError, /must respond to to_h/)
    end
  end

  describe "value validation" do
    it "accepts nil values" do
      args = described_class.new({value: nil})
      expect(args[:value]).to be_nil
    end

    it "accepts boolean values" do
      args = described_class.new({enabled: true, disabled: false})
      expect(args[:enabled]).to eq(true)
      expect(args[:disabled]).to eq(false)
    end

    it "accepts String values" do
      args = described_class.new({name: "test"})
      expect(args[:name]).to eq("test")
    end

    it "accepts Integer values" do
      args = described_class.new({count: 42})
      expect(args[:count]).to eq(42)
    end

    it "accepts Float values" do
      args = described_class.new({rate: 3.14})
      expect(args[:rate]).to eq(3.14)
    end

    it "accepts nested Arrays with valid types" do
      args = described_class.new({items: [1, "two", 3.0, nil, true]})
      expect(args[:items]).to eq([1, "two", 3.0, nil, true])
    end

    it "accepts nested Hashes with valid types and stringifies keys" do
      args = described_class.new({config: {enabled: true, count: 5}})
      expect(args[:config]).to eq({"enabled" => true, "count" => 5})
    end

    it "deeply stringifies keys in nested hashes" do
      args = described_class.new({
        level1: {
          level2: {
            level3: "deep"
          }
        }
      })
      expect(args[:level1]).to eq({"level2" => {"level3" => "deep"}})
    end

    it "deeply stringifies hash keys inside arrays" do
      args = described_class.new({
        items: [
          {name: "first", id: 1},
          {name: "second", id: 2}
        ]
      })
      expect(args[:items]).to eq([
        {"name" => "first", "id" => 1},
        {"name" => "second", "id" => 2}
      ])
    end

    it "handles deeply nested arrays and hashes" do
      args = described_class.new({
        data: [
          {
            nested: [
              {deep: {value: 123}}
            ]
          }
        ]
      })
      expect(args[:data]).to eq([
        {
          "nested" => [
            {"deep" => {"value" => 123}}
          ]
        }
      ])
    end

    it "rejects Symbol values" do
      expect do
        described_class.new({status: :active})
      end.to raise_error(ArgumentError, /must be a JSON-native type.*got Symbol/)
    end

    it "rejects custom objects" do
      custom_obj = Object.new
      expect do
        described_class.new({obj: custom_obj})
      end.to raise_error(ArgumentError, /must be a JSON-native type/)
    end

    it "rejects Date values" do
      expect do
        described_class.new({date: Date.today})
      end.to raise_error(ArgumentError, /must be a JSON-native type.*got Date/)
    end

    it "rejects Symbols nested in arrays" do
      expect do
        described_class.new({items: %i[one two]})
      end.to raise_error(ArgumentError, /must be a JSON-native type.*got Symbol/)
    end

    it "rejects invalid types nested in hashes" do
      expect do
        described_class.new({config: {date: Date.today}})
      end.to raise_error(ArgumentError, /must be a JSON-native type/)
    end
  end

  describe "#[]" do
    let(:args) { described_class.new({user_id: 123, name: "test"}) }

    it "returns value for existing key with symbol" do
      expect(args[:user_id]).to eq(123)
    end

    it "returns value for existing key with string" do
      expect(args["user_id"]).to eq(123)
    end

    it "raises KeyError for non-existent key" do
      expect do
        args[:missing]
      end.to raise_error(KeyError, /key not found: :missing/)
    end

    it "includes available keys in error message" do
      expect do
        args[:missing]
      end.to raise_error(KeyError, /Available keys:.*user_id.*name/)
    end
  end

  describe "#fetch" do
    let(:args) { described_class.new({user_id: 123}) }

    it "returns value for existing key" do
      expect(args.fetch(:user_id)).to eq(123)
    end

    it "returns default for non-existent key" do
      expect(args.fetch(:missing, "default")).to eq("default")
    end

    it "returns nil for non-existent key when no default given" do
      expect(args.fetch(:missing)).to be_nil
    end

    it "works with string keys" do
      expect(args.fetch("user_id")).to eq(123)
    end
  end

  describe "#include?" do
    let(:args) { described_class.new({user_id: 123}) }

    it "returns true for existing key with symbol" do
      expect(args.include?(:user_id)).to eq(true)
    end

    it "returns true for existing key with string" do
      expect(args.include?("user_id")).to eq(true)
    end

    it "returns false for non-existent key" do
      expect(args.include?(:missing)).to eq(false)
    end
  end

  describe "#to_h" do
    it "returns hash with symbol keys" do
      args = described_class.new({user_id: 123, name: "test"})
      expect(args.to_h).to eq({user_id: 123, name: "test"})
    end

    it "returns empty hash for empty args" do
      args = described_class.new(nil)
      expect(args.to_h).to eq({})
    end
  end

  describe "#as_json / #dump" do
    it "returns hash with string keys" do
      args = described_class.new({user_id: 123, name: "test"})
      expect(args.as_json).to eq({"user_id" => 123, "name" => "test"})
    end

    it "dump is an alias for as_json" do
      args = described_class.new({user_id: 123})
      expect(args.dump).to eq(args.as_json)
    end
  end

  describe ".load" do
    it "creates CallbackArgs from hash with string keys" do
      hash = {"user_id" => 123, "name" => "test"}
      args = described_class.load(hash)
      expect(args[:user_id]).to eq(123)
      expect(args[:name]).to eq("test")
    end

    it "creates empty CallbackArgs from nil" do
      args = described_class.load(nil)
      expect(args).to be_empty
    end

    it "creates empty CallbackArgs from empty hash" do
      args = described_class.load({})
      expect(args).to be_empty
    end

    it "skips validation on load" do
      # This allows loading data that was already serialized
      hash = {"user_id" => 123}
      args = described_class.load(hash)
      expect(args[:user_id]).to eq(123)
    end
  end

  describe "#empty?" do
    it "returns true for empty args" do
      expect(described_class.new(nil)).to be_empty
      expect(described_class.new({})).to be_empty
    end

    it "returns false for non-empty args" do
      expect(described_class.new({foo: "bar"})).not_to be_empty
    end
  end

  describe "#size / #length" do
    it "returns the number of arguments" do
      args = described_class.new({a: 1, b: 2, c: 3})
      expect(args.size).to eq(3)
      expect(args.length).to eq(3)
    end
  end

  describe "#keys" do
    it "returns the keys as strings" do
      args = described_class.new({user_id: 123, name: "test"})
      expect(args.keys).to contain_exactly("user_id", "name")
    end
  end

  describe "round trip" do
    it "serializes and deserializes correctly" do
      original = {user_id: 123, config: {enabled: true}, items: [1, 2, 3]}
      args = described_class.new(original)
      serialized = args.as_json
      restored = described_class.load(serialized)

      # Top-level keys are symbolized via to_h, but nested hashes have string keys
      expect(restored.to_h).to eq({
        user_id: 123,
        config: {"enabled" => true},
        items: [1, 2, 3]
      })
    end

    it "preserves deeply nested structure through serialization" do
      original = {
        user_id: 123,
        metadata: {
          tags: %w[a b],
          settings: {level: 5}
        }
      }
      args = described_class.new(original)
      serialized = args.as_json
      restored = described_class.load(serialized)

      expect(restored[:user_id]).to eq(123)
      expect(restored[:metadata]).to eq({
        "tags" => %w[a b],
        "settings" => {"level" => 5}
      })
    end
  end
end
