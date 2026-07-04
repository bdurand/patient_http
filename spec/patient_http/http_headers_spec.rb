# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::HttpHeaders do
  describe "#[]" do
    it "retrieves values case insensitively" do
      headers = described_class.new("Content-Type" => "application/json")

      expect(headers["content-type"]).to eq("application/json")
      expect(headers["Content-Type"]).to eq("application/json")
      expect(headers[:"content-type"]).to eq("application/json")
    end
  end

  describe "#[]=" do
    it "sets values with lowercase keys" do
      headers = described_class.new
      headers["X-Custom"] = "value"

      expect(headers.to_h).to eq({"x-custom" => "value"})
    end
  end

  describe "#fetch" do
    it "returns the value or the default" do
      headers = described_class.new("Accept" => "application/json")

      expect(headers.fetch("ACCEPT")).to eq("application/json")
      expect(headers.fetch("missing", "default")).to eq("default")
    end
  end

  describe "#merge" do
    it "returns a new instance with the merged headers" do
      headers = described_class.new("Accept" => "application/json")
      merged = headers.merge("X-Custom" => "1")

      expect(merged.to_h).to eq({"accept" => "application/json", "x-custom" => "1"})
    end

    it "does not mutate the receiver" do
      headers = described_class.new("Accept" => "application/json")
      headers.merge("X-Custom" => "1")

      expect(headers.to_h).to eq({"accept" => "application/json"})
    end
  end

  describe "#except" do
    it "returns a new instance without the specified headers" do
      headers = described_class.new("Authorization" => "token", "Accept" => "application/json")
      filtered = headers.except("AUTHORIZATION")

      expect(filtered.to_h).to eq({"accept" => "application/json"})
      expect(headers.to_h).to eq({"authorization" => "token", "accept" => "application/json"})
    end
  end

  describe "#dup" do
    it "does not share storage with the original" do
      headers = described_class.new("Accept" => "application/json")
      copy = headers.dup
      copy["X-Custom"] = "1"

      expect(headers.include?("x-custom")).to be false
      expect(copy["x-custom"]).to eq("1")
    end
  end

  describe "#include?" do
    it "checks for headers case insensitively" do
      headers = described_class.new("Accept" => "application/json")

      expect(headers.include?("ACCEPT")).to be true
      expect(headers.include?("missing")).to be false
    end
  end
end
