# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Encryptor do
  let(:secret_key) { "test-secret-key-for-encryption!!" }

  let(:encryption) { ->(data) { data.bytes.map { |b| b ^ 0x42 }.pack("C*") } }
  let(:decryption) { ->(data) { data.bytes.map { |b| b ^ 0x42 }.pack("C*") } }

  let(:encryptor) { described_class.new(encryption: encryption, decryption: decryption) }
  let(:noop_encryptor) { described_class.new }

  describe "#encrypt" do
    it "returns nil when data is nil" do
      expect(encryptor.encrypt(nil)).to be_nil
    end

    it "raises ArgumentError when data is not a Hash" do
      expect { encryptor.encrypt("string") }.to raise_error(ArgumentError, "Data is not a Hash")
      expect { encryptor.encrypt(123) }.to raise_error(ArgumentError, "Data is not a Hash")
      expect { encryptor.encrypt([1, 2]) }.to raise_error(ArgumentError, "Data is not a Hash")
    end

    it "returns the original data when no encryption callable is set" do
      data = {"foo" => "bar", "count" => 42}
      expect(noop_encryptor.encrypt(data)).to eq(data)
    end

    it "encrypts data and returns a hash with __encrypted__ flag" do
      data = {"foo" => "bar"}
      result = encryptor.encrypt(data)

      expect(result).to be_a(Hash)
      expect(result["__encrypted__"]).to eq(true)
      expect(result["value"]).to be_a(String)
    end

    it "base64 encodes the encrypted value" do
      data = {"foo" => "bar"}
      result = encryptor.encrypt(data)

      # The value should be valid base64
      expect { result["value"].unpack1("m") }.not_to raise_error
    end

    it "produces encrypted output that can be decrypted back" do
      data = {"foo" => "bar", "nested" => {"a" => 1}}
      encrypted = encryptor.encrypt(data)
      decrypted = encryptor.decrypt(encrypted)

      expect(decrypted).to eq(data)
    end
  end

  describe "#decrypt" do
    it "returns nil when data is nil" do
      expect(encryptor.decrypt(nil)).to be_nil
    end

    it "raises ArgumentError when data is not a Hash" do
      expect { encryptor.decrypt("string") }.to raise_error(ArgumentError, "Data is not a Hash")
      expect { encryptor.decrypt(123) }.to raise_error(ArgumentError, "Data is not a Hash")
      expect { encryptor.decrypt([1, 2]) }.to raise_error(ArgumentError, "Data is not a Hash")
    end

    it "returns the original data when no decryption callable is set" do
      data = {"foo" => "bar"}
      expect(noop_encryptor.decrypt(data)).to eq(data)
    end

    it "returns the original data when data is not marked as encrypted" do
      data = {"foo" => "bar"}
      expect(encryptor.decrypt(data)).to eq(data)
    end

    it "returns nil when encrypted value is nil" do
      data = {"__encrypted__" => true, "value" => nil}
      expect(encryptor.decrypt(data)).to be_nil
    end

    it "decrypts encrypted data back to the original hash" do
      original = {"key" => "value", "number" => 42, "flag" => true}
      encrypted = encryptor.encrypt(original)
      decrypted = encryptor.decrypt(encrypted)

      expect(decrypted).to eq(original)
    end

    it "handles nested hash data" do
      original = {"outer" => {"inner" => {"deep" => "value"}}}
      encrypted = encryptor.encrypt(original)
      decrypted = encryptor.decrypt(encrypted)

      expect(decrypted).to eq(original)
    end

    it "handles arrays in data" do
      original = {"items" => [1, "two", 3.0, nil, true]}
      encrypted = encryptor.encrypt(original)
      decrypted = encryptor.decrypt(encrypted)

      expect(decrypted).to eq(original)
    end
  end

  describe "round-trip" do
    it "preserves empty hashes" do
      original = {}
      encrypted = encryptor.encrypt(original)
      decrypted = encryptor.decrypt(encrypted)

      expect(decrypted).to eq(original)
    end

    it "preserves unicode strings" do
      original = {"emoji" => "\u{1F600}", "japanese" => "\u3053\u3093\u306B\u3061\u306F"}
      encrypted = encryptor.encrypt(original)
      decrypted = encryptor.decrypt(encrypted)

      expect(decrypted).to eq(original)
    end

    it "works with noop encryptor for unencrypted data" do
      data = {"foo" => "bar"}
      encrypted = noop_encryptor.encrypt(data)
      decrypted = noop_encryptor.decrypt(encrypted)

      expect(decrypted).to eq(data)
    end
  end
end
