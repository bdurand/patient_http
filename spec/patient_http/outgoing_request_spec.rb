# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::OutgoingRequest do
  let(:headers) do
    PatientHttp::HttpHeaders.new("authorization" => "Bearer token123", "x-request-id" => "req-1")
  end

  let(:outgoing) do
    described_class.new(
      http_method: :post,
      url: "https://api.example.com/users?page=2",
      headers: headers,
      body: '{"name":"Alice"}'
    )
  end

  it "exposes the http method, url, headers, and body" do
    expect(outgoing.http_method).to eq(:post)
    expect(outgoing.url).to eq("https://api.example.com/users?page=2")
    expect(outgoing.headers).to be(headers)
    expect(outgoing.body).to eq('{"name":"Alice"}')
  end

  describe "#headers" do
    it "can be changed case insensitively" do
      outgoing.headers["X-Signature"] = "abc123"
      expect(outgoing.headers["x-signature"]).to eq("abc123")
      expect(outgoing.headers["Authorization"]).to eq("Bearer token123")
    end
  end

  describe "#add_param" do
    it "appends an encoded query parameter to a url with an existing query" do
      outgoing.add_param(:signature, "a+b/c=")
      expect(outgoing.url).to eq("https://api.example.com/users?page=2&signature=a%2Bb%2Fc%3D")
    end

    it "appends a query parameter to a url without a query" do
      outgoing = described_class.new(
        http_method: :get,
        url: "https://api.example.com/users",
        headers: PatientHttp::HttpHeaders.new,
        body: nil
      )
      outgoing.add_param("api_key", "k3y")
      expect(outgoing.url).to eq("https://api.example.com/users?api_key=k3y")
    end
  end

  describe "#inspect" do
    it "shows the method, url without the query string, and header names" do
      value = outgoing.inspect
      expect(value).to include("POST")
      expect(value).to include("https://api.example.com/users")
      expect(value).to include("authorization")
    end

    it "does not include header values, the query string, or the body" do
      value = outgoing.inspect
      expect(value).not_to include("page=2")
      expect(value).not_to include("Bearer token123")
      expect(value).not_to include("Alice")
    end
  end
end
