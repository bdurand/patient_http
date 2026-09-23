# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Connection Timeout Integration", :integration do
  let(:config) do
    PatientHttp::Configuration.new(
      max_connections: 3,
      request_timeout: 5,
      connection_timeout: 0.2
    )
  end

  let(:processor) { PatientHttp::Processor.new(config) }

  around do |example|
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!

    test_web_server.start.ready?

    processor.run do
      example.run
    end
  ensure
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  def run_request(request)
    handler = TestTaskHandler.new({"class" => "Worker", "jid" => "connect-timeout", "args" => []})
    task = PatientHttp::RequestTask.new(request: request, task_handler: handler, callback: TestCallback)
    processor.enqueue(task)
    processor.wait_for_idle(timeout: 5)
    handler
  end

  context "when the server pauses longer than the connection timeout mid-response" do
    it "delivers the response because only the request timeout bounds the read" do
      # The delay endpoint streams five chunks, so a 1500ms delay pauses 300ms
      # between chunks, longer than the 200ms connection timeout.
      template = PatientHttp::RequestTemplate.new(base_url: test_web_server.base_url)
      handler = run_request(template.get("/delay/1500"))

      expect(handler.errors).to be_empty
      expect(handler.completions.size).to eq(1)

      response = handler.completions.first[:response]
      expect(response.status).to eq(200)
      expect(response.body).to include('"chunk":4')
    end
  end

  context "when the server pauses longer than the connection timeout on a reused connection" do
    it "delivers both responses" do
      template = PatientHttp::RequestTemplate.new(base_url: test_web_server.base_url)
      run_request(template.get("/test/200"))
      handler = run_request(template.get("/delay/1500"))

      expect(handler.errors).to be_empty
      expect(handler.completions.size).to eq(1)
    end
  end

  context "when a request runs inline and the server pauses longer than the connection timeout" do
    it "delivers the response through the synchronous executor" do
      TestCallback.reset_calls!
      template = PatientHttp::RequestTemplate.new(base_url: test_web_server.base_url)
      handler = TestTaskHandler.new({"class" => "Worker", "jid" => "inline-connect-timeout", "args" => []})
      task = PatientHttp::RequestTask.new(
        request: template.get("/delay/1500"), task_handler: handler, callback: TestCallback
      )

      PatientHttp::SynchronousExecutor.new(task, config: config).call

      expect(TestCallback.error_calls).to be_empty
      expect(TestCallback.completion_calls.size).to eq(1)
      expect(TestCallback.completion_calls.first.body).to include('"chunk":4')
    end
  end

  context "when the server accepts the TCP connection but never completes the TLS handshake" do
    # A listening socket that is never read from: the kernel completes the TCP
    # handshake, so the client's TLS ClientHello goes unanswered.
    let(:silent_server) { TCPServer.new("127.0.0.1", 0) }

    after do
      silent_server.close
    end

    it "fails with a timeout error once the connection timeout elapses" do
      template = PatientHttp::RequestTemplate.new(base_url: "https://127.0.0.1:#{silent_server.addr[1]}")
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      handler = run_request(template.get("/unreachable"))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      expect(handler.completions).to be_empty
      expect(handler.errors.size).to eq(1)

      error = handler.errors.first[:error]
      expect(error.error_type).to eq(:timeout)
      expect(error.error_class).to eq(IO::TimeoutError)
      expect(elapsed).to be < 2
    end
  end
end
