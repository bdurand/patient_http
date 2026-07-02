# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::RequestPreparer do
  let(:config) do
    PatientHttp::Configuration.new(user_agent: "TestAgent/1.0").tap do |c|
      c.register_secret(:auth_header, "Bearer s3cr3t")
      c.register_secret(:api_key, "k3y")
    end
  end

  let(:preparer) { described_class.new(config) }

  describe "#prepare" do
    it "resolves secrets and sets the send-time headers" do
      request = PatientHttp::Request.new(
        :post,
        "https://api.example.com/users",
        headers: {"Authorization" => PatientHttp.secret(:auth_header), "Content-Type" => "application/json"},
        params: {"api_key" => PatientHttp.secret(:api_key), "page" => 2},
        body: '{"name":"Alice"}'
      )

      outgoing = preparer.prepare(request, "req-1")

      expect(outgoing.url).to eq("https://api.example.com/users?page=2&api_key=k3y")
      expect(outgoing.headers["authorization"]).to eq("Bearer s3cr3t")
      expect(outgoing.headers["content-type"]).to eq("application/json")
      expect(outgoing.headers["x-request-id"]).to eq("req-1")
      expect(outgoing.headers["user-agent"]).to eq("TestAgent/1.0")
      expect(outgoing.body).to eq('{"name":"Alice"}')
    end

    it "does not override a user-agent set on the request" do
      request = PatientHttp::Request.new(:get, "https://api.example.com", headers: {"User-Agent" => "Custom/2.0"})
      outgoing = preparer.prepare(request, "req-1")
      expect(outgoing.headers["user-agent"]).to eq("Custom/2.0")
    end

    it "invokes preprocessors with the resolved outgoing request" do
      seen = nil
      config.register_preprocessor(:signer) do |outgoing_request|
        seen = {
          http_method: outgoing_request.http_method,
          url: outgoing_request.url,
          request_id: outgoing_request.headers["x-request-id"],
          authorization: outgoing_request.headers["authorization"],
          body: outgoing_request.body
        }
        outgoing_request.headers["x-signature"] = "signed"
      end

      request = PatientHttp::Request.new(
        :post,
        "https://api.example.com/users",
        headers: {"Authorization" => PatientHttp.secret(:auth_header)},
        params: {"api_key" => PatientHttp.secret(:api_key)},
        body: "payload",
        preprocessors: :signer
      )

      outgoing = preparer.prepare(request, "req-2")

      expect(seen).to eq(
        http_method: :post,
        url: "https://api.example.com/users?api_key=k3y",
        request_id: "req-2",
        authorization: "Bearer s3cr3t",
        body: "payload"
      )
      expect(outgoing.headers["x-signature"]).to eq("signed")
    end

    it "invokes preprocessors in order, each seeing the previous changes" do
      config.register_preprocessor(:first) { |r| r.headers["x-one"] = "1" }
      config.register_preprocessor(:second) do |r|
        r.headers["x-two"] = "#{r.headers["x-one"]}2"
        r.add_param("signed", "yes")
      end

      request = PatientHttp::Request.new(:get, "https://api.example.com", preprocessors: [:first, :second])
      outgoing = preparer.prepare(request, "req-3")

      expect(outgoing.headers["x-one"]).to eq("1")
      expect(outgoing.headers["x-two"]).to eq("12")
      expect(outgoing.url).to eq("https://api.example.com?signed=yes")
    end

    it "raises PreprocessorNotFoundError for an unregistered preprocessor" do
      request = PatientHttp::Request.new(:get, "https://api.example.com", preprocessors: :missing)
      expect {
        preparer.prepare(request, "req-4")
      }.to raise_error(described_class::PreprocessorNotFoundError, /missing/)
    end
  end
end
