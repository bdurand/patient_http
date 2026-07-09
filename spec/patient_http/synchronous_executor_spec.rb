# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::SynchronousExecutor do
  let(:config) { PatientHttp::Configuration.new }

  def create_task(method: :get, url: "https://api.example.com/data", max_redirects: nil, raise_error_responses: false)
    request = PatientHttp::Request.new(method, url, max_redirects: max_redirects)
    task_handler = TestTaskHandler.new({"class" => "TestWorker", "jid" => SecureRandom.uuid, "args" => []})
    PatientHttp::RequestTask.new(
      request: request,
      task_handler: task_handler,
      callback: TestCallback,
      raise_error_responses: raise_error_responses
    )
  end

  before do
    TestCallback.reset_calls!
  end

  describe "#call" do
    it "invokes the callback on_complete with the response" do
      stub_request(:get, "https://api.example.com/data")
        .to_return(status: 200, body: "hello", headers: {"Content-Type" => "text/plain"})

      task = create_task
      on_complete_results = []
      executor = described_class.new(
        task,
        config: config,
        on_complete: ->(response) { on_complete_results << response }
      )
      executor.call

      expect(TestCallback.error_calls).to be_empty
      expect(TestCallback.completion_calls.size).to eq(1)

      response = TestCallback.completion_calls.first
      expect(response.status).to eq(200)
      expect(response.body).to eq("hello")
      expect(response.request_id).to eq(task.original_id)
      expect(on_complete_results).to eq([response])
    end

    it "follows redirects and reports the original request id" do
      stub_request(:get, "https://api.example.com/old")
        .to_return(status: 302, headers: {"Location" => "https://api.example.com/new"})
      stub_request(:get, "https://api.example.com/new")
        .to_return(status: 200, body: "final", headers: {})

      task = create_task(url: "https://api.example.com/old")
      described_class.new(task, config: config).call

      expect(TestCallback.error_calls).to be_empty
      expect(TestCallback.completion_calls.size).to eq(1)

      response = TestCallback.completion_calls.first
      expect(response.status).to eq(200)
      expect(response.redirects).to eq(["https://api.example.com/old"])
      expect(response.request_id).to eq(task.original_id)
    end

    it "invokes the error callback exactly once when there are too many redirects" do
      (1..10).each do |i|
        stub_request(:get, "https://api.example.com/#{i}")
          .to_return(status: 302, headers: {"Location" => "https://api.example.com/#{i + 1}"})
      end

      task = create_task(url: "https://api.example.com/1", max_redirects: 3)
      on_error_results = []
      executor = described_class.new(
        task,
        config: config,
        on_error: ->(error) { on_error_results << error }
      )
      executor.call

      expect(TestCallback.completion_calls).to be_empty
      expect(TestCallback.error_calls.size).to eq(1)

      error = TestCallback.error_calls.first
      expect(error).to be_a(PatientHttp::TooManyRedirectsError)
      expect(on_error_results).to eq([error])
    end

    it "invokes the error callback exactly once for a recursive redirect" do
      stub_request(:get, "https://api.example.com/loop")
        .to_return(status: 302, headers: {"Location" => "https://api.example.com/loop"})

      task = create_task(url: "https://api.example.com/loop")
      described_class.new(task, config: config).call

      expect(TestCallback.completion_calls).to be_empty
      expect(TestCallback.error_calls.size).to eq(1)
      expect(TestCallback.error_calls.first).to be_a(PatientHttp::RecursiveRedirectError)
    end

    it "invokes the error callback with an HttpError when raise_error_responses is set" do
      stub_request(:get, "https://api.example.com/data").to_return(status: 500, body: "oops")

      task = create_task(raise_error_responses: true)
      described_class.new(task, config: config).call

      expect(TestCallback.completion_calls).to be_empty
      expect(TestCallback.error_calls.size).to eq(1)
      expect(TestCallback.error_calls.first).to be_a(PatientHttp::ServerError)
    end

    it "invokes the error callback with a RequestError when the request raises" do
      stub_request(:get, "https://api.example.com/data").to_raise(Errno::ECONNREFUSED)

      task = create_task
      described_class.new(task, config: config).call

      expect(TestCallback.completion_calls).to be_empty
      expect(TestCallback.error_calls.size).to eq(1)

      error = TestCallback.error_calls.first
      expect(error).to be_a(PatientHttp::RequestError)
      expect(error.error_type).to eq(:connection)
    end
  end
end
