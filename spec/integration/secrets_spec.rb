# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Secret Resolution Integration", :integration do
  include Async::RSpec::Reactor

  let(:config) do
    PatientHttp::Configuration.new(max_connections: 10, request_timeout: 5).tap do |c|
      c.register_secret(:auth_header, "Bearer s3cr3t-token")
      c.register_secret(:api_key) { "resolved-api_key" }
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

  it "dereferences secret headers and query params when the processor sends the request" do
    request = PatientHttp::Request.new(
      :get,
      "#{test_web_server.base_url}/test/200",
      headers: {"Authorization" => PatientHttp.secret(:auth_header)},
      params: {"api_key" => PatientHttp.secret(:api_key), "page" => 2}
    )

    # The serialized request must never contain the secret values.
    serialized = JSON.generate(request.as_json)
    expect(serialized).not_to include("s3cr3t-token")
    expect(serialized).to include("$secret")

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

    # The test server echoes the headers and query string it actually received.
    expect(body["headers"]["authorization"]).to eq("Bearer s3cr3t-token")
    expect(body["query_string"]).to include("page=2")
    expect(body["query_string"]).to include("api_key=resolved-api_key")
  end
end
