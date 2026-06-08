# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SecretReference do
  describe "#initialize" do
    it "stores the name as a string" do
      expect(described_class.new(:api_token).name).to eq("api_token")
      expect(described_class.new("api_token").name).to eq("api_token")
    end

    it "raises when the name is empty" do
      expect { described_class.new("") }.to raise_error(ArgumentError)
      expect { described_class.new(nil) }.to raise_error(ArgumentError)
    end
  end

  describe ".reference?" do
    it "is true for a SecretReference instance" do
      expect(described_class.reference?(described_class.new(:token))).to be(true)
    end

    it "is true for a serialized marker hash" do
      expect(described_class.reference?({"$secret" => "token"})).to be(true)
    end

    it "is false for other values" do
      expect(described_class.reference?("token")).to be(false)
      expect(described_class.reference?({"other" => "token"})).to be(false)
      expect(described_class.reference?(nil)).to be(false)
    end
  end

  describe ".load" do
    it "reconstructs a SecretReference from a marker hash" do
      ref = described_class.load({"$secret" => "token"})
      expect(ref).to be_a(described_class)
      expect(ref.name).to eq("token")
    end

    it "returns non-marker values unchanged" do
      expect(described_class.load("plain")).to eq("plain")
      ref = described_class.new(:token)
      expect(described_class.load(ref)).to be(ref)
    end
  end

  describe "#as_json" do
    it "serializes to a marker hash containing only the name" do
      expect(described_class.new(:api_token).as_json).to eq("$secret" => "api_token")
    end
  end

  describe "equality" do
    it "is equal when names match" do
      expect(described_class.new(:token)).to eq(described_class.new("token"))
      expect(described_class.new(:token)).not_to eq(described_class.new(:other))
    end

    it "can be used as a hash key" do
      hash = {described_class.new(:token) => 1}
      expect(hash[described_class.new(:token)]).to eq(1)
    end
  end

  describe "#inspect" do
    it "shows only the name (never a value)" do
      expect(described_class.new(:api_token).inspect).to eq('#<PatientHttp::SecretReference name="api_token">')
    end
  end
end
