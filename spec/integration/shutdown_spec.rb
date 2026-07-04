# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Processor Shutdown Integration", :integration do
  include Async::RSpec::Reactor

  let(:config) do
    PatientHttp::Configuration.new(
      max_connections: 10,
      request_timeout: 10
    )
  end

  let!(:processor) { PatientHttp::Processor.new(config) }

  around do |example|
    processor.run do
      example.run
    end
  end

  before do
    # Disable WebMock completely for integration tests
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end

  after do
    # Re-enable WebMock
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  describe "clean shutdown with completion" do
    it "allows in-flight requests to complete when timeout is sufficient" do
      # Build request
      template = PatientHttp::RequestTemplate.new(base_url: test_web_server.base_url)
      request = template.get("/test/200")

      # Create request task
      handler = TestTaskHandler.new({
        "class" => "Worker",
        "jid" => "test-jid-clean",
        "args" => []
      })

      request_task = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler,
        callback: TestCallback,
        callback_args: {arg1: "arg1", arg2: "arg2"}
      )

      # Enqueue request
      processor.enqueue(request_task)

      # Wait for request to complete
      processor.wait_for_idle(timeout: 2)

      # Stop with sufficient timeout (2 seconds for a fast request)
      processor.stop

      # Verify on_complete was called (request completed)
      expect(handler.completions.size).to eq(1)
      response = handler.completions.first[:response]
      expect(response).to be_a(PatientHttp::Response)
      expect(response.status).to eq(200)
      # Verify response contains request info
      response_data = JSON.parse(response.body)
      expect(response_data["status"]).to eq(200)
      expect(response.callback_args.as_json).to eq({"arg1" => "arg1", "arg2" => "arg2"})

      # Verify task was NOT re-enqueued
      expect(handler.retries).to be_empty

      # Verify processor is stopped
      expect(processor.stopped?).to be true
    end
  end

  describe "in-flight requests completing during shutdown" do
    it "delivers responses that complete during the stop window and returns before the timeout" do
      template = PatientHttp::RequestTemplate.new(base_url: test_web_server.base_url)
      request = template.get("/delay/300")

      handler = TestTaskHandler.new({
        "class" => "Worker",
        "jid" => "test-jid-graceful",
        "args" => []
      })

      request_task = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler,
        callback: TestCallback
      )

      processor.enqueue(request_task)

      # Wait for the request to be in flight, then stop while it is running
      processor.wait_for_processing

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      processor.stop(timeout: 10)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      # The 300ms request completed during the stop window and was delivered
      expect(handler.completions.size).to eq(1)
      expect(handler.completions.first[:response].status).to eq(200)

      # The request was not re-enqueued since it completed
      expect(handler.retries).to be_empty

      # Stop returned as soon as the request finished, not after the full timeout
      expect(elapsed).to be < 5

      expect(processor.stopped?).to be true
    end
  end

  describe "forced shutdown with re-enqueue" do
    it "re-enqueues in-flight requests when timeout is insufficient" do
      # Build request
      template = PatientHttp::RequestTemplate.new(base_url: test_web_server.base_url)
      request = template.get("/delay/250")

      # Create request task
      handler = TestTaskHandler.new({
        "class" => "Worker",
        "jid" => "test-jid-forced",
        "args" => %w[original_arg1 original_arg2]
      })

      request_task = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler,
        callback: TestCallback
      )

      # Enqueue request
      processor.enqueue(request_task)

      # Wait for request to start processing
      processor.wait_for_processing
      # Give it a bit more time to really get in-flight
      sleep(0.05)

      # Stop with insufficient timeout (0.01 seconds for a 250ms request)
      processor.stop(timeout: 0.01)

      # Verify task was re-enqueued via task_handler.retry
      expect(handler.retries.size).to eq(1)
      expect(handler.retries.first["args"]).to eq(%w[original_arg1 original_arg2])

      # Verify on_complete was NOT called (request did not complete)
      expect(handler.completions).to be_empty

      # Verify processor is stopped
      expect(processor.stopped?).to be true
    end
  end

  describe "multiple in-flight requests during shutdown" do
    it "completes fast requests and re-enqueues slow requests" do
      # Build and enqueue 5 requests
      template = PatientHttp::RequestTemplate.new(base_url: test_web_server.base_url)
      task_handlers = []

      5.times do |i|
        request = template.get("/delay/#{i.even? ? 100 : 500}")

        handler = TestTaskHandler.new({
          "class" => "Worker",
          "jid" => "test-jid-#{i + 1}",
          "args" => ["request_#{i + 1}"]
        })
        task_handlers << handler

        request_task = PatientHttp::RequestTask.new(
          request: request,
          task_handler: handler,
          callback: TestCallback,
          callback_args: {request_name: "request_#{i + 1}"}
        )

        processor.enqueue(request_task)
      end

      processor.wait_for_processing
      # Wait a bit longer to let fast requests (100ms) get close to completion
      sleep(0.25)

      # Stop with medium timeout (200ms)
      # Fast requests (100ms) should complete during this timeout
      # Slow requests (500ms) should be re-enqueued
      processor.stop(timeout: 0.2)

      # Wait briefly for re-enqueue to happen
      sleep(0.05)

      # Verify on_complete was called for fast requests (1, 3, 5)
      all_completions = task_handlers.flat_map(&:completions)
      expect(all_completions.size).to eq(3)
      success_args = all_completions.map { |c| c[:response].callback_args["request_name"] }
      expect(success_args).to contain_exactly("request_1", "request_3", "request_5")

      # Verify slow requests were re-enqueued (2, 4)
      all_retries = task_handlers.flat_map(&:retries)
      expect(all_retries.size).to eq(2)
      retry_args = all_retries.map { |r| r["args"][0] }
      expect(retry_args).to contain_exactly("request_2", "request_4")

      # Verify total callbacks equals 5 (all requests accounted for)
      total_callbacks = all_completions.size + all_retries.size
      expect(total_callbacks).to eq(5)

      # Verify processor is stopped
      expect(processor.stopped?).to be true
    end
  end
end
