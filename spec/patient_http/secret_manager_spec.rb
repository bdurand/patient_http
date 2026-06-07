# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SecretManager do
  def ref(name)
    PatientHttp::SecretReference.new(name)
  end

  describe "#include?" do
    it "returns true for registered secret names" do
      manager = described_class.new(secrets: {"token" => "abc123"})
      expect(manager.include?(:token)).to be true
      expect(manager.include?("token")).to be true
      expect(manager.include?(:missing)).to be false
    end
  end

  describe "#resolve" do
    it "resolves a static value from the registry" do
      manager = described_class.new(secrets: {"token" => "abc123"})
      expect(manager.resolve(:token)).to eq("abc123")
    end

    it "invokes a callable registry value with the name" do
      manager = described_class.new(secrets: {"token" => ->(name) { "value-for-#{name}" }})
      expect(manager.resolve(:token)).to eq("value-for-token")
    end

    it "coerces the resolved value to a string" do
      manager = described_class.new(secrets: {"token" => 12345})
      expect(manager.resolve(:token)).to eq("12345")
    end

    it "raises SecretNotFoundError when unresolved" do
      manager = described_class.new
      expect { manager.resolve(:missing) }.to raise_error(
        described_class::SecretNotFoundError, /missing/
      )
    end
  end

  describe "#resolve_headers" do
    let(:manager) { described_class.new(secrets: {"token" => "abc123"}) }

    it "replaces secret references with their resolved values" do
      result = manager.resolve_headers("authorization" => ref(:token), "accept" => "application/json")
      expect(result).to eq("authorization" => "abc123", "accept" => "application/json")
    end

    it "resolves serialized marker hashes too" do
      result = manager.resolve_headers("authorization" => {"$secret" => "token"})
      expect(result).to eq("authorization" => "abc123")
    end

    it "returns a new hash and leaves non-secret values untouched" do
      headers = {"accept" => "application/json"}
      result = manager.resolve_headers(headers)
      expect(result).to eq(headers)
      expect(result).not_to be(headers)
    end

    it "returns nil when given nil" do
      expect(manager.resolve_headers(nil)).to be_nil
    end
  end

  describe "#resolve_url" do
    let(:manager) { described_class.new(secrets: {"api_key" => "k3y"}) }

    it "returns the url unchanged when there are no secret params" do
      expect(manager.resolve_url("https://example.com/path", {})).to eq("https://example.com/path")
      expect(manager.resolve_url("https://example.com/path", nil)).to eq("https://example.com/path")
    end

    it "appends resolved secret params to a url with no query" do
      url = manager.resolve_url("https://example.com/path", {"api_key" => ref(:api_key)})
      expect(url).to eq("https://example.com/path?api_key=k3y")
    end

    it "merges resolved secret params into an existing query string" do
      url = manager.resolve_url("https://example.com/path?page=2", {"api_key" => ref(:api_key)})
      expect(url).to eq("https://example.com/path?page=2&api_key=k3y")
    end
  end
end
