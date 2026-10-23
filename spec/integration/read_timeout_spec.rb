# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Read timeout and per-request response size", :integration do
  let(:config) do
    PatientHttp::Configuration.new(
      max_connections: 3,
      request_timeout: 5,
      retries: 3
    )
  end

  around do |example|
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!

    test_web_server.start.ready?
    example.run
  ensure
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  def stream_url(**params)
    "#{test_web_server.base_url}/stream?#{URI.encode_www_form(params)}"
  end

  def gzip_url(size)
    "#{test_web_server.base_url}/gzip?size=#{size}"
  end

  shared_examples "read timeout and response size limits" do
    describe "read_timeout" do
      it "raises a read timeout while it waits for the response headers" do
        request = PatientHttp::Request.new(:get, stream_url(header_delay: 1000), read_timeout: 0.2)

        result, elapsed = timed_run(request)

        expect(result).to be_a(PatientHttp::RequestError)
        expect(result.error_type).to eq(:timeout)
        expect(result.error_class).to eq(PatientHttp::ReadTimeoutError)
        expect(elapsed).to be < 0.8
      end

      it "raises a read timeout when the stream stops between chunks" do
        request = PatientHttp::Request.new(:get, stream_url(chunks: 3, stall: 1500), read_timeout: 0.3)

        result, elapsed = timed_run(request)

        expect(result).to be_a(PatientHttp::RequestError)
        expect(result.error_type).to eq(:timeout)
        expect(result.error_class).to eq(PatientHttp::ReadTimeoutError)
        expect(elapsed).to be < 1.2
      end

      it "reads a slow but steady stream that takes longer than the read timeout in total" do
        request = PatientHttp::Request.new(
          :get,
          stream_url(chunks: 8, size: 4, interval: 150),
          read_timeout: 0.4
        )

        result, elapsed = timed_run(request)

        expect(result).to be_a(PatientHttp::Response)
        expect(result.body).to eq((0...8).map { |i| i.to_s.ljust(4, ".") }.join)
        expect(elapsed).to be > 0.4
      end

      it "uses the configured read timeout when the request does not set one" do
        config.read_timeout = 0.2
        request = PatientHttp::Request.new(:get, stream_url(header_delay: 1000))

        result, _elapsed = timed_run(request)

        expect(result.error_class).to eq(PatientHttp::ReadTimeoutError)
      end

      it "lets the request timeout stop a steady stream" do
        request = PatientHttp::Request.new(
          :get,
          stream_url(chunks: 30, interval: 100),
          timeout: 0.6,
          read_timeout: 0.4
        )

        result, elapsed = timed_run(request)

        expect(result).to be_a(PatientHttp::RequestError)
        expect(result.error_type).to eq(:timeout)
        expect(result.error_class).to eq(Async::TimeoutError)
        expect(elapsed).to be < 1.5
      end

      [:get, :post].each do |http_method|
        it "does not retry a #{http_method.upcase} request after a read timeout" do
          key = SecureRandom.hex(8)
          body = (http_method == :post) ? "{}" : nil
          request = PatientHttp::Request.new(
            http_method,
            stream_url(key: key, header_delay: 600),
            body: body,
            read_timeout: 0.2
          )

          result, _elapsed = timed_run(request)

          expect(result.error_class).to eq(PatientHttp::ReadTimeoutError)
          expect(test_web_server.hits(key)).to eq(1)
        end
      end
    end

    describe "max_response_size" do
      it "rejects a body larger than the request limit" do
        config.max_response_size = 100_000
        request = PatientHttp::Request.new(
          :get,
          stream_url(chunks: 4, size: 1000),
          max_response_size: 2000
        )

        result, _elapsed = timed_run(request)

        expect(result).to be_a(PatientHttp::RequestError)
        expect(result.error_type).to eq(:response_too_large)
      end

      it "accepts a body larger than the configured limit when the request limit allows it" do
        config.max_response_size = 2000
        request = PatientHttp::Request.new(
          :get,
          stream_url(chunks: 4, size: 1000),
          max_response_size: 10_000
        )

        result, _elapsed = timed_run(request)

        expect(result).to be_a(PatientHttp::Response)
        expect(result.body.bytesize).to eq(4000)
      end

      it "applies the request limit to the content-length header" do
        config.max_response_size = 100_000
        request = PatientHttp::Request.new(
          :get,
          "#{test_web_server.base_url}/test/200",
          max_response_size: 10
        )

        result, _elapsed = timed_run(request)

        expect(result.error_type).to eq(:response_too_large)
        expect(result.message).to match(/exceeds maximum allowed size \(10 bytes\)/)
      end

      it "applies the request limit to the inflated body" do
        config.max_response_size = 1_000_000
        request = PatientHttp::Request.new(:get, gzip_url(50_000), max_response_size: 10_000)

        result, _elapsed = timed_run(request)

        expect(result).to be_a(PatientHttp::RequestError)
        expect(result.error_type).to eq(:response_too_large)
      end

      it "inflates a body larger than the configured limit when the request limit allows it" do
        config.max_response_size = 10_000
        request = PatientHttp::Request.new(:get, gzip_url(50_000), max_response_size: 100_000)

        result, _elapsed = timed_run(request)

        expect(result).to be_a(PatientHttp::Response)
        expect(result.body).to eq("a" * 50_000)
      end
    end
  end

  context "with a processor" do
    let(:processor) { PatientHttp::Processor.new(config) }

    around do |example|
      processor.run { example.run }
    end

    def timed_run(request)
      handler = TestTaskHandler.new({"class" => "Worker", "jid" => SecureRandom.hex(8), "args" => []})
      task = PatientHttp::RequestTask.new(request: request, task_handler: handler, callback: TestCallback)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      processor.enqueue(task)
      processor.wait_for_idle(timeout: 5)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      results = handler.completions.map { |c| c[:response] } + handler.errors.map { |e| e[:error] }
      expect(results.size).to eq(1)
      [results.first, elapsed]
    end

    include_examples "read timeout and response size limits"
  end

  context "with the synchronous executor" do
    before { TestCallback.reset_calls! }

    def timed_run(request)
      handler = TestTaskHandler.new({"class" => "Worker", "jid" => SecureRandom.hex(8), "args" => []})
      task = PatientHttp::RequestTask.new(request: request, task_handler: handler, callback: TestCallback)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      PatientHttp::SynchronousExecutor.new(task, config: config).call
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

      results = TestCallback.completion_calls + TestCallback.error_calls
      expect(results.size).to eq(1)
      [results.first, elapsed]
    end

    include_examples "read timeout and response size limits"
  end
end
