# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::RedirectError do
  describe ".load" do
    it "reconstructs TooManyRedirectsError from hash" do
      hash = {
        "error_class" => PatientHttp::TooManyRedirectsError.name,
        "url" => "https://example.com/final",
        "http_method" => "get",
        "duration" => 1.0,
        "request_id" => "req-789",
        "redirects" => ["https://example.com/1", "https://example.com/2"],
        "callback_args" => {"key" => "value"}
      }

      error = described_class.load(hash)

      expect(error).to be_a(PatientHttp::TooManyRedirectsError)
      expect(error.url).to eq("https://example.com/final")
      expect(error.http_method).to eq(:get)
      expect(error.redirects).to eq(["https://example.com/1", "https://example.com/2"])
      expect(error.callback_args[:key]).to eq("value")
    end

    it "reconstructs RecursiveRedirectError from hash" do
      hash = {
        "error_class" => PatientHttp::RecursiveRedirectError,
        "url" => "https://example.com/cycle",
        "http_method" => "post",
        "duration" => 0.5,
        "request_id" => "req-cycle",
        "redirects" => ["https://example.com/1", "https://example.com/2"],
        "callback_args" => {}
      }

      error = described_class.load(hash)

      expect(error).to be_a(PatientHttp::RecursiveRedirectError)
      expect(error.url).to eq("https://example.com/cycle")
      expect(error.http_method).to eq(:post)
    end

    it "raises an error if the error class is not a RedirectError" do
      hash = {
        "error_class" => "PatientHttp::Response",
        "url" => "https://example.com/final",
        "http_method" => "get",
        "duration" => 1.0,
        "request_id" => "req-789",
        "redirects" => [],
        "callback_args" => {}
      }

      expect { described_class.load(hash) }.to raise_error(ArgumentError, /Invalid redirect error class/)
    end
  end
end

RSpec.describe PatientHttp::TooManyRedirectsError do
  describe "#initialize" do
    it "creates an error with redirect details" do
      error = described_class.new(
        url: "https://example.com/redirect4",
        http_method: :get,
        duration: 1.5,
        request_id: "req-123",
        redirects: ["https://example.com/start", "https://example.com/redirect1", "https://example.com/redirect2"],
        callback_args: {"user_id" => 123}
      )

      expect(error.url).to eq("https://example.com/redirect4")
      expect(error.http_method).to eq(:get)
      expect(error.duration).to eq(1.5)
      expect(error.request_id).to eq("req-123")
      expect(error.redirects).to eq(["https://example.com/start", "https://example.com/redirect1", "https://example.com/redirect2"])
      expect(error.error_type).to eq(:redirect)
      expect(error.error_class).to eq(PatientHttp::TooManyRedirectsError)
      expect(error.callback_args[:user_id]).to eq(123)
      expect(error.message).to include("Too many redirects")
      expect(error.message).to include("3")
    end
  end

  describe "#as_json" do
    it "returns hash with string keys" do
      error = described_class.new(
        url: "https://example.com/final",
        http_method: :post,
        duration: 2.0,
        request_id: "req-456",
        redirects: ["https://example.com/a", "https://example.com/b"],
        callback_args: {"action" => "fetch"}
      )

      hash = error.as_json

      expect(hash["error_class"]).to eq(PatientHttp::TooManyRedirectsError.name)
      expect(hash["url"]).to eq("https://example.com/final")
      expect(hash["http_method"]).to eq("post")
      expect(hash["duration"]).to eq(2.0)
      expect(hash["request_id"]).to eq("req-456")
      expect(hash["redirects"]).to eq(["https://example.com/a", "https://example.com/b"])
      expect(hash["callback_args"]).to eq({"action" => "fetch"})
    end
  end

  describe "round-trip serialization" do
    it "preserves all data through as_json and load" do
      original = described_class.new(
        url: "https://example.com/end",
        http_method: :put,
        duration: 3.5,
        request_id: "req-abc",
        redirects: ["https://example.com/x", "https://example.com/y", "https://example.com/z"],
        callback_args: {"id" => 999}
      )

      hash = original.as_json
      restored = PatientHttp::RedirectError.load(hash)

      expect(restored).to be_a(PatientHttp::TooManyRedirectsError)
      expect(restored.url).to eq(original.url)
      expect(restored.http_method).to eq(original.http_method)
      expect(restored.duration).to eq(original.duration)
      expect(restored.request_id).to eq(original.request_id)
      expect(restored.redirects).to eq(original.redirects)
      expect(restored.callback_args.to_h).to eq(original.callback_args.to_h)
    end
  end
end

RSpec.describe PatientHttp::RecursiveRedirectError do
  describe "#initialize" do
    it "creates an error with redirect loop details" do
      error = described_class.new(
        url: "https://example.com/loop",
        http_method: :get,
        duration: 0.8,
        request_id: "req-loop",
        redirects: ["https://example.com/a", "https://example.com/b", "https://example.com/loop"],
        callback_args: {"retry" => true}
      )

      expect(error.url).to eq("https://example.com/loop")
      expect(error.http_method).to eq(:get)
      expect(error.duration).to eq(0.8)
      expect(error.request_id).to eq("req-loop")
      expect(error.redirects).to eq(["https://example.com/a", "https://example.com/b", "https://example.com/loop"])
      expect(error.error_type).to eq(:redirect)
      expect(error.error_class).to eq(PatientHttp::RecursiveRedirectError)
      expect(error.callback_args[:retry]).to eq(true)
      expect(error.message).to include("Recursive redirect")
      expect(error.message).to include("https://example.com/loop")
    end
  end

  describe "round-trip serialization" do
    it "preserves all data through as_json and load" do
      original = described_class.new(
        url: "https://example.com/back",
        http_method: :delete,
        duration: 1.2,
        request_id: "req-del",
        redirects: ["https://example.com/forward", "https://example.com/back"],
        callback_args: {"attempt" => 3}
      )

      hash = original.as_json
      restored = PatientHttp::RedirectError.load(hash)

      expect(restored).to be_a(PatientHttp::RecursiveRedirectError)
      expect(restored.url).to eq(original.url)
      expect(restored.http_method).to eq(original.http_method)
      expect(restored.duration).to eq(original.duration)
      expect(restored.request_id).to eq(original.request_id)
      expect(restored.redirects).to eq(original.redirects)
      expect(restored.callback_args.to_h).to eq(original.callback_args.to_h)
    end
  end
end
