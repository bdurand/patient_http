# frozen_string_literal: true

require "spec_helper"
require "openssl"

RSpec.describe "Request Preprocessor Integration", :integration do
  include Async::RSpec::Reactor

  let(:signing_key) { "s1gning-k3y" }

  let(:config) do
    key = signing_key
    PatientHttp::Configuration.new(max_connections: 10, request_timeout: 5).tap do |c|
      c.register_secret(:auth_header, "Bearer s3cr3t-token")
      c.register_preprocessor(:signer) do |outgoing|
        data = "#{outgoing.http_method.to_s.upcase}\n#{outgoing.url}\n#{outgoing.headers["x-request-id"]}\n#{outgoing.body}"
        outgoing.headers["x-signature"] = OpenSSL::HMAC.hexdigest("SHA256", key, data)
        outgoing.headers["x-signed"] = "true"
      end
    end
  end

  let(:processor) { PatientHttp::Processor.new(config) }

  around do |example|
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!

    processor.run do
      example.run
    end
  ensure
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  it "applies preprocessors when the processor sends the request" do
    request = PatientHttp::Request.new(
      :post,
      "#{test_web_server.base_url}/test/200",
      headers: {"Authorization" => PatientHttp.secret(:auth_header)},
      body: "payload",
      preprocessors: :signer
    )

    # Only the preprocessor name is serialized with the request.
    serialized = JSON.generate(request.as_json)
    expect(serialized).to include("signer")
    expect(serialized).not_to include(signing_key)

    handler = TestTaskHandler.new({"class" => "Worker", "jid" => "jid-1", "args" => []})
    task = PatientHttp::RequestTask.new(
      request: PatientHttp::Request.load(JSON.parse(serialized)),
      task_handler: handler,
      callback: TestCallback
    )

    processor.enqueue(task)
    processor.wait_for_idle(timeout: 2)

    expect(handler.completions.size).to eq(1)
    body = JSON.parse(handler.completions.first[:response].body)

    # The test server echoes the headers it actually received. The signature must
    # recompute from the echoed request id and the actual URL and body, proving the
    # preprocessor saw the fully resolved outgoing request.
    headers = body["headers"]
    expect(headers["x-signed"]).to eq("true")
    expect(headers["authorization"]).to eq("Bearer s3cr3t-token")

    expected_data = "POST\n#{test_web_server.base_url}/test/200\n#{headers["x-request-id"]}\npayload"
    expect(headers["x-signature"]).to eq(OpenSSL::HMAC.hexdigest("SHA256", signing_key, expected_data))
  end
end
