# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Configuration do
  subject(:config) { described_class.new }

  describe "#encryption" do
    it "sets the encryption callable used by the encryptor" do
      callable = ->(data) { "encrypted:#{data}" }
      config.encryption(callable)
      expect(config.encryptor.encrypt({"key" => "value"})).to include("__encrypted__" => true)
    end

    it "accepts a block as the encryption callable" do
      config.encryption { |data| "encrypted:#{data}" }
      expect(config.encryptor.encrypt({"key" => "value"})).to include("__encrypted__" => true)
    end

    it "raises ArgumentError when both a callable and a block are provided" do
      expect {
        config.encryption(->(data) { data }) { |data| data }
      }.to raise_error(ArgumentError, /encryption accepts either a callable argument or a block/)
    end

    it "raises ArgumentError when the callable does not respond to #call" do
      expect {
        config.encryption("not_a_callable")
      }.to raise_error(ArgumentError, /encryption callable must respond to #call/)
    end

    it "clears encryption when set to nil" do
      config.encryption(->(data) { data })
      config.encryption(nil)
      data = {"key" => "value"}
      expect(config.encryptor.encrypt(data)).to eq(data)
    end

    it "resets the cached encryptor when changed" do
      original_encryptor = config.encryptor
      config.encryption(->(data) { data })
      expect(config.encryptor).not_to equal(original_encryptor)
    end
  end

  describe "#decryption" do
    it "sets the decryption callable used by the encryptor" do
      encrypt = ->(data) { data.reverse }
      decrypt = ->(data) { data.reverse }
      config.encryption(encrypt)
      config.decryption(decrypt)
      original = {"key" => "value"}
      encrypted = config.encryptor.encrypt(original)
      expect(config.encryptor.decrypt(encrypted)).to eq(original)
    end

    it "accepts a block as the decryption callable" do
      config.decryption { |data| data }
      expect(config.encryptor.decrypt({"key" => "value"})).to eq({"key" => "value"})
    end

    it "raises ArgumentError when both a callable and a block are provided" do
      expect {
        config.decryption(->(data) { data }) { |data| data }
      }.to raise_error(ArgumentError, /decryption accepts either a callable argument or a block/)
    end

    it "raises ArgumentError when the callable does not respond to #call" do
      expect {
        config.decryption("not_a_callable")
      }.to raise_error(ArgumentError, /decryption callable must respond to #call/)
    end

    it "clears decryption when set to nil" do
      config.decryption(->(data) { data })
      config.decryption(nil)
      data = {"__encrypted__" => true, "value" => "test"}
      expect(config.encryptor.decrypt(data)).to eq(data)
    end

    it "resets the cached encryptor when changed" do
      original_encryptor = config.encryptor
      config.decryption(->(data) { data })
      expect(config.encryptor).not_to equal(original_encryptor)
    end
  end

  describe "#encryption_key=" do
    context "when ActiveSupport::MessageEncryptor is available" do
      before { skip "ActiveSupport::MessageEncryptor not available" unless defined?(ActiveSupport::MessageEncryptor) }

      it "sets up working encryption and decryption" do
        config.encryption_key = "secret_key"
        original = {"user_id" => 42, "token" => "abc123"}
        encrypted = config.encryptor.encrypt(original)

        expect(encrypted["__encrypted__"]).to eq(true)
        expect(config.encryptor.decrypt(encrypted)).to eq(original)
      end

      it "produces a stable key so encrypted data survives across restarts" do
        config1 = described_class.new(encryption_key: "stable_key")
        config2 = described_class.new(encryption_key: "stable_key")

        original = {"data" => "sensitive"}
        encrypted = config1.encryptor.encrypt(original)

        expect(config2.encryptor.decrypt(encrypted)).to eq(original)
      end

      it "supports key rotation — new key encrypts, old key can still decrypt" do
        old_config = described_class.new(encryption_key: "old_key")
        original = {"data" => "value"}
        encrypted_with_old_key = old_config.encryptor.encrypt(original)

        rotated_config = described_class.new(encryption_key: ["new_key", "old_key"])
        expect(rotated_config.encryptor.decrypt(encrypted_with_old_key)).to eq(original)
      end

      it "encrypts new data with the first (primary) key after rotation" do
        rotated_config = described_class.new(encryption_key: ["new_key", "old_key"])
        original = {"data" => "value"}
        encrypted = rotated_config.encryptor.encrypt(original)

        new_only_config = described_class.new(encryption_key: "new_key")
        expect(new_only_config.encryptor.decrypt(encrypted)).to eq(original)
      end

      it "disables encryption when set to nil" do
        config.encryption_key = "secret"
        config.encryption_key = nil
        data = {"key" => "value"}
        expect(config.encryptor.encrypt(data)).to eq(data)
      end

      it "disables encryption when set to an empty string" do
        config.encryption_key = "secret"
        config.encryption_key = ""
        data = {"key" => "value"}
        expect(config.encryptor.encrypt(data)).to eq(data)
      end
    end

    context "when ActiveSupport::MessageEncryptor is not available" do
      before { skip "ActiveSupport::MessageEncryptor is available" if defined?(ActiveSupport::MessageEncryptor) }

      it "raises ArgumentError" do
        expect {
          config.encryption_key = "secret_key"
        }.to raise_error(ArgumentError, /ActiveSupport::MessageEncryptor is required/)
      end
    end
  end

  describe "#register_secret" do
    it "registers a static value resolvable through the secret manager" do
      config.register_secret(:api_token, "abc123")
      expect(config.secret_manager.resolve(:api_token)).to eq("abc123")
    end

    it "registers a block evaluated lazily at resolve time" do
      value = "first"
      config.register_secret(:api_token) { value }
      manager = config.secret_manager
      value = "second"
      expect(manager.resolve(:api_token)).to eq("second")
    end

    it "raises when neither a value nor a block is given" do
      expect { config.register_secret(:api_token) }.to raise_error(ArgumentError, /value or a block/)
    end

    it "raises when both a value and a block are given" do
      expect {
        config.register_secret(:api_token, "abc") { "xyz" }
      }.to raise_error(ArgumentError, /not both/)
    end

    it "invalidates the memoized secret manager" do
      first = config.secret_manager
      config.register_secret(:api_token, "abc123")
      expect(config.secret_manager).not_to be(first)
    end
  end

  describe "#protocol=" do
    it "defaults to nil" do
      expect(config.protocol).to be_nil
    end

    it "accepts :http1 and :http2" do
      config.protocol = :http1
      expect(config.protocol).to eq(:http1)

      config.protocol = :http2
      expect(config.protocol).to eq(:http2)
    end

    it "normalizes strings to symbols" do
      config.protocol = "http1"
      expect(config.protocol).to eq(:http1)
    end

    it "can be reset to nil" do
      config.protocol = :http1
      config.protocol = nil
      expect(config.protocol).to be_nil
    end

    it "raises ArgumentError for unsupported values" do
      expect { config.protocol = :spdy }.to raise_error(ArgumentError, /protocol must be one of/)
    end

    it "is included in to_h" do
      config.protocol = :http1
      expect(config.to_h["protocol"]).to eq(:http1)
    end
  end

  describe "#to_h" do
    it "exposes registered secret names but never their values" do
      config.register_secret(:api_token, "super-secret")
      hash = config.to_h
      expect(hash["secrets"]).to eq(["api_token"])
      expect(hash.to_s).not_to include("super-secret")
    end
  end
end
