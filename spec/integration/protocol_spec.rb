# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Forced Protocol Integration", :integration do
  include Async::RSpec::Reactor

  let(:config) do
    PatientHttp::Configuration.new(
      max_connections: 10,
      request_timeout: 5,
      protocol: :http1
    )
  end

  let(:processor) { PatientHttp::Processor.new(config) }

  around do |example|
    # Disable WebMock completely for integration tests
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!

    processor.run do
      example.run
    end
  ensure
    # Re-enable WebMock
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  it "completes requests when the protocol is forced to HTTP/1.1" do
    template = PatientHttp::RequestTemplate.new(base_url: test_web_server.base_url)
    request = template.get("/test/200")

    handler = TestTaskHandler.new({
      "class" => "Worker",
      "jid" => "protocol-test-jid",
      "args" => []
    })

    request_task = PatientHttp::RequestTask.new(
      request: request,
      task_handler: handler,
      callback: TestCallback
    )

    processor.enqueue(request_task)
    processor.wait_for_idle(timeout: 2)

    expect(handler.completions.size).to eq(1)
    expect(handler.completions.first[:response].status).to eq(200)
  end
end
