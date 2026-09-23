# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Connection Eviction Integration", :integration do
  let(:config) do
    PatientHttp::Configuration.new(
      max_connections: 10,
      request_timeout: 5
    )
  end

  let(:processor) { PatientHttp::Processor.new(config) }

  # The test server answers on both names, and the client pool keys clients by
  # host name, so the two URLs exercise two independent pooled clients.
  let(:slow_host) { test_web_server.base_url }
  let(:other_host) { test_web_server.base_url.sub("localhost", "127.0.0.1") }

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

  def enqueue(url, timeout: nil)
    handler = TestTaskHandler.new({"class" => "Worker", "jid" => url, "args" => []})
    request = PatientHttp::Request.new(:get, url, timeout: timeout)
    task = PatientHttp::RequestTask.new(request: request, task_handler: handler, callback: TestCallback)
    processor.enqueue(task)
    handler
  end

  def wait_for_result(handler, timeout:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until handler.completions.any? || handler.errors.any?
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.01
    end
  end

  context "when a request times out while another request to the same host is in flight" do
    it "keeps dispatching requests to other hosts while the evicted client drains" do
      slow = enqueue("#{slow_host}/delay/1500")
      timed_out = enqueue("#{slow_host}/delay/1000", timeout: 0.1)
      wait_for_result(timed_out, timeout: 2)
      expect(timed_out.errors.size).to eq(1)

      other = enqueue("#{other_host}/test/200")
      wait_for_result(other, timeout: 1)

      expect(other.completions.size).to eq(1)
      expect(slow.completions).to be_empty

      processor.wait_for_idle(timeout: 5)
      expect(slow.completions.size).to eq(1)
    end

    it "closes the evicted client once its in-flight request finishes" do
      client_pool = processor.instance_variable_get(:@http_client).instance_variable_get(:@client_pool)
      evicted_client = client_pool.client_for(Async::HTTP::Endpoint.parse(slow_host))

      enqueue("#{slow_host}/delay/300")
      timed_out = enqueue("#{slow_host}/delay/1000", timeout: 0.1)
      wait_for_result(timed_out, timeout: 2)
      expect(client_pool.size).to eq(0)

      processor.wait_for_idle(timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      sleep 0.01 until evicted_client.pool.empty? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      expect(evicted_client.pool).to be_empty
    end
  end
end
