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

  describe "#register_preprocessor" do
    it "registers a block retrievable by name" do
      config.register_preprocessor(:signer) { |request| request.headers["x-signature"] = "signed" }
      expect(config.preprocessor(:signer)).to be_a(Proc)
    end

    it "registers a callable retrievable by string or symbol name" do
      callable = ->(request) { request }
      config.register_preprocessor(:signer, callable)
      expect(config.preprocessor(:signer)).to be(callable)
      expect(config.preprocessor("signer")).to be(callable)
    end

    it "accepts a callable object with a call method" do
      klass = Class.new do
        def call(request)
          request
        end
      end
      config.register_preprocessor(:signer, klass.new)
      expect(config.preprocessor(:signer)).to respond_to(:call)
    end

    it "returns nil for an unregistered preprocessor" do
      expect(config.preprocessor(:missing)).to be_nil
    end

    it "raises when neither a callable nor a block is given" do
      expect { config.register_preprocessor(:signer) }.to raise_error(ArgumentError, /callable or a block/)
    end

    it "raises when both a callable and a block are given" do
      expect {
        config.register_preprocessor(:signer, ->(_request) {}) { |request| request }
      }.to raise_error(ArgumentError, /not both/)
    end

    it "raises when the callable does not accept an argument" do
      expect {
        config.register_preprocessor(:signer, -> {})
      }.to raise_error(ArgumentError, /single argument/)
    end

    it "raises when a block does not accept an argument" do
      expect {
        config.register_preprocessor(:signer) { "value" }
      }.to raise_error(ArgumentError, /single argument/)
    end

    it "raises when the callable requires more than one argument" do
      expect {
        config.register_preprocessor(:signer, ->(_a, _b) {})
      }.to raise_error(ArgumentError, /single argument/)
    end

    it "raises when the callable requires keyword arguments" do
      expect {
        config.register_preprocessor(:signer, ->(_request, _other:) {})
      }.to raise_error(ArgumentError, /single argument/)
    end

    it "includes preprocessor names in to_h" do
      config.register_preprocessor(:signer) { |request| request }
      expect(config.to_h["preprocessors"]).to eq(["signer"])
    end
  end

  describe "#tcp_keepalive=" do
    it "defaults to nil" do
      expect(config.tcp_keepalive).to be_nil
    end

    it "treats an integer as the idle time with default probe settings" do
      config.tcp_keepalive = 30
      expect(config.tcp_keepalive).to eq({idle: 30, interval: 10, count: 3})
    end

    it "accepts a hash with idle, interval, and count" do
      config.tcp_keepalive = {"idle" => 45, "interval" => 7, "count" => 4}
      expect(config.tcp_keepalive).to eq({idle: 45, interval: 7, count: 4})
    end

    it "accepts nil to disable keepalive" do
      config.tcp_keepalive = 30
      config.tcp_keepalive = nil
      expect(config.tcp_keepalive).to be_nil
    end

    it "rejects unknown keys" do
      expect { config.tcp_keepalive = {idle: 30, probes: 3} }
        .to raise_error(ArgumentError, /unknown keys: \[:probes\]/)
    end

    it "rejects a non-positive idle time" do
      expect { config.tcp_keepalive = 0 }.to raise_error(ArgumentError, /tcp_keepalive_idle/)
    end

    it "rejects a fractional interval" do
      expect { config.tcp_keepalive = {idle: 30, interval: 2.5} }
        .to raise_error(ArgumentError, /tcp_keepalive_interval/)
    end

    it "can be set through the constructor" do
      configured = described_class.new(tcp_keepalive: 60)
      expect(configured.tcp_keepalive).to eq({idle: 60, interval: 10, count: 3})
    end
  end

  describe "#tcp_user_timeout=" do
    it "defaults to nil" do
      expect(config.tcp_user_timeout).to be_nil
    end

    it "accepts a positive number of seconds" do
      config.tcp_user_timeout = 30
      expect(config.tcp_user_timeout).to eq(30)
    end

    it "accepts fractional seconds" do
      config.tcp_user_timeout = 2.5
      expect(config.tcp_user_timeout).to eq(2.5)
    end

    it "accepts nil to use the kernel default" do
      config.tcp_user_timeout = 30
      config.tcp_user_timeout = nil
      expect(config.tcp_user_timeout).to be_nil
    end

    it "rejects a non-positive value" do
      expect { config.tcp_user_timeout = 0 }.to raise_error(ArgumentError, /tcp_user_timeout/)
    end

    it "can be set through the constructor" do
      configured = described_class.new(tcp_user_timeout: 45)
      expect(configured.tcp_user_timeout).to eq(45)
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

  describe "#max_connections_per_host=" do
    it "defaults to nil (unlimited)" do
      expect(config.max_connections_per_host).to be_nil
    end

    it "accepts a positive integer" do
      config.max_connections_per_host = 32
      expect(config.max_connections_per_host).to eq(32)
    end

    it "accepts nil to remove the limit" do
      config.max_connections_per_host = 32
      config.max_connections_per_host = nil
      expect(config.max_connections_per_host).to be_nil
    end

    it "rejects non-positive values" do
      expect { config.max_connections_per_host = 0 }.to raise_error(ArgumentError, /positive integer/)
    end

    it "is included in to_h" do
      config.max_connections_per_host = 16
      expect(config.to_h["max_connections_per_host"]).to eq(16)
    end
  end

  describe "#follow_method_changing_redirects=" do
    it "defaults to true" do
      expect(config.follow_method_changing_redirects).to be true
    end

    it "accepts false" do
      config.follow_method_changing_redirects = false
      expect(config.follow_method_changing_redirects).to be false
    end

    it "rejects values that are not booleans" do
      expect { config.follow_method_changing_redirects = nil }.to raise_error(ArgumentError, /true or false/)
    end

    it "is included in to_h" do
      expect(config.to_h["follow_method_changing_redirects"]).to be true
    end
  end

  describe "#redirect_strip_headers=" do
    it "defaults to an empty array" do
      expect(config.redirect_strip_headers).to eq([])
    end

    it "normalizes names to lowercase" do
      config.redirect_strip_headers = ["X-Api-Key", :"X-Internal-Token"]
      expect(config.redirect_strip_headers).to eq(["x-api-key", "x-internal-token"])
    end

    it "accepts a single header name" do
      config.redirect_strip_headers = "X-Api-Key"
      expect(config.redirect_strip_headers).to eq(["x-api-key"])
    end

    it "rejects values that are not strings" do
      expect { config.redirect_strip_headers = [/^x-internal-/] }.to raise_error(ArgumentError, /must be strings/)
    end

    it "is included in to_h" do
      config.redirect_strip_headers = ["X-Api-Key"]
      expect(config.to_h["redirect_strip_headers"]).to eq(["x-api-key"])
    end
  end

  describe "#completion_threads=" do
    it "defaults to 2" do
      expect(config.completion_threads).to eq(2)
    end

    it "accepts a positive integer" do
      config.completion_threads = 4
      expect(config.completion_threads).to eq(4)
    end

    it "rejects zero" do
      expect { config.completion_threads = 0 }.to raise_error(ArgumentError, /positive integer/)
    end

    it "is included in to_h" do
      expect(config.to_h["completion_threads"]).to eq(2)
    end
  end

  describe "#completion_retries=" do
    it "defaults to 2" do
      expect(config.completion_retries).to eq(2)
    end

    it "accepts zero to disable retries" do
      config.completion_retries = 0
      expect(config.completion_retries).to eq(0)
    end

    it "rejects negative values" do
      expect { config.completion_retries = -1 }.to raise_error(ArgumentError, /non-negative integer/)
    end

    it "is included in to_h" do
      expect(config.to_h["completion_retries"]).to eq(2)
    end
  end
end
