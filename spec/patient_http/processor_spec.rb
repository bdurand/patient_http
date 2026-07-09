# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Processor do
  let(:config) { PatientHttp::Configuration.new }
  let(:processor) { described_class.new(config) }

  # Helper to create request tasks for testing
  def create_request_task(
    method: :get,
    url: "https://api.example.com/users",
    headers: {},
    body: nil,
    timeout: 30,
    worker_class: "TestWorker",
    jid: nil,
    job_args: [],
    callback: "TestCallback",
    callback_args: {}
  )
    request = PatientHttp::Request.new(
      method,
      url,
      headers: headers,
      body: body,
      timeout: timeout
    )
    task_handler = TestTaskHandler.new({"class" => worker_class, "jid" => jid || SecureRandom.uuid, "args" => job_args})
    PatientHttp::RequestTask.new(
      request: request,
      task_handler: task_handler,
      callback: callback,
      callback_args: callback_args
    )
  end

  # Mock request task object matching the expected structure
  let(:mock_request) do
    create_request_task(
      headers: {"Accept" => "application/json"},
      jid: "jid-123",
      job_args: [],
      callback_args: {"id" => 1, "arg" => "test_arg"}
    )
  end

  after do
    processor.stop
  end

  describe ".new" do
    it "starts in stopped state" do
      expect(processor).to be_stopped
      expect(processor.state).to eq(:stopped)
    end
  end

  describe "#start" do
    it "sets the state to running" do
      processor.start
      expect(processor).to be_running
      expect(processor.state).to eq(:running)
    end

    it "spawns a reactor thread" do
      processor.start
      expect(processor.instance_variable_get(:@reactor_thread)).to be_alive
    end

    it "names the reactor thread" do
      processor.start
      thread = processor.instance_variable_get(:@reactor_thread)
      expect(thread.name).to eq("patient-http-processor")
    end

    it "does not start if already running" do
      processor.start
      old_thread = processor.instance_variable_get(:@reactor_thread)
      processor.start
      new_thread = processor.instance_variable_get(:@reactor_thread)
      expect(old_thread).to eq(new_thread)
    end

    it "resets the shutdown barrier" do
      lifecycle = processor.instance_variable_get(:@lifecycle)
      # Transition to running then stopping to signal shutdown
      lifecycle.start!
      lifecycle.running!
      lifecycle.stop! # This sets the shutdown barrier
      expect(lifecycle.shutdown_signaled?).to be true

      lifecycle.stopped!  # Reset to stopped
      lifecycle.start!    # This should reset the barrier
      expect(lifecycle.shutdown_signaled?).to be false
    end
  end

  describe "#stop" do
    context "when not running" do
      it "does nothing if already stopped" do
        expect(processor).to be_stopped
        processor.stop
        expect(processor).to be_stopped
      end
    end

    context "when running" do
      around do |example|
        processor.run do
          example.run
        end
      end

      it "sets the state to stopping then stopped" do
        processor.stop
        expect(processor).to be_stopped
      end

      it "signals the shutdown barrier" do
        lifecycle = processor.instance_variable_get(:@lifecycle)
        processor.stop
        expect(lifecycle.shutdown_signaled?).to be true
      end

      context "with timeout" do
        it "waits for in-flight requests to complete" do
          # Simulate an in-flight request that completes quickly
          inflight = processor.instance_variable_get(:@inflight_requests)
          inflight["fake-id"] = double("task")

          Thread.new do
            sleep 0.05
            processor.instance_variable_get(:@tasks_lock).synchronize do
              inflight.delete("fake-id")
              processor.instance_variable_get(:@idle_condition).broadcast
            end
          end.join

          start_time = Time.now
          processor.stop(timeout: 0.5)
          elapsed = Time.now - start_time

          # Should wait but not exceed timeout significantly
          expect(elapsed).to be < 1.0
        end

        it "does not wait longer than timeout" do
          # A real in-flight request that outlives the stop timeout. (A bare
          # double can't stand in here: it isn't a reactor fiber, so the reactor
          # would drain it immediately and stop would return before the timeout.)
          stub_request(:get, "https://api.example.com/users").to_return do
            sleep(0.3)
            {status: 200, body: "", headers: {}}
          end

          processor.enqueue(create_request_task)
          processor.wait_for_processing(timeout: 1)

          start_time = Time.now
          processor.stop(timeout: 0.1)
          elapsed = Time.now - start_time

          # Waits about the timeout for the stuck request, then gives up.
          expect(elapsed).to be_between(0.08, 1.5)
        end
      end
    end
  end

  describe "#drain" do
    it "sets the state to draining when running" do
      processor.run do
        processor.drain
        expect(processor).to be_draining
        expect(processor.state).to eq(:draining)
      end
    end

    it "does nothing if not running" do
      expect(processor).to be_stopped
      processor.drain
      expect(processor).to be_stopped
    end

    it "cannot be restarted while draining" do
      processor.run do
        processor.drain
        reactor_thread = processor.instance_variable_get(:@reactor_thread)

        processor.start

        expect(processor).to be_draining
        expect(processor.instance_variable_get(:@reactor_thread)).to eq(reactor_thread)
      end
    end
  end

  describe "#observe" do
    it "allows observers to call back into the processor" do
      observer_class = Class.new(PatientHttp::ProcessorObserver) do
        attr_reader :count_at_start

        def initialize(processor)
          @processor = processor
          @count_at_start = nil
        end

        def start
          @count_at_start = @processor.total_count
        end
      end

      observer = observer_class.new(processor)

      processor.run do
        processor.observe(observer)
        expect(observer.count_at_start).to eq(0)
      end
    end
  end

  describe "#enqueue" do
    let(:request) { create_request_task }

    context "when draining" do
      around do |example|
        processor.run do
          example.run
        end
      end

      it "raises an error" do
        processor.drain
        expect do
          processor.enqueue(request)
        end.to raise_error(PatientHttp::NotRunningError,
          /Cannot enqueue request: processor is draining/)
      end
    end

    context "when stopped" do
      it "raises an error" do
        expect do
          processor.enqueue(request)
        end.to raise_error(PatientHttp::NotRunningError,
          /Cannot enqueue request: processor is stopped/)
      end
    end

    context "when stopping" do
      it "raises an error" do
        lifecycle = processor.instance_variable_get(:@lifecycle)
        lifecycle.start!
        lifecycle.running!
        lifecycle.stop!
        expect do
          processor.enqueue(request)
        end.to raise_error(PatientHttp::NotRunningError,
          /Cannot enqueue request: processor is stopping/)
      ensure
        lifecycle&.stopped!
      end
    end
  end

  describe "state predicates" do
    describe "#running?" do
      it "returns true when state is running" do
        processor.run do
          expect(processor.running?).to be true
        end
      end

      it "returns false when state is not running" do
        expect(processor.running?).to be false
      end
    end

    describe "#stopped?" do
      it "returns true when state is stopped" do
        expect(processor.stopped?).to be true
      end

      it "returns false when state is not stopped" do
        processor.run do
          expect(processor.stopped?).to be false
        end
      end
    end

    describe "#draining?" do
      it "returns true when state is draining" do
        processor.run do
          processor.drain
          expect(processor.draining?).to be true
        end
      end

      it "returns false when state is not draining" do
        expect(processor.draining?).to be false
      end
    end

    describe "#stopping?" do
      it "returns true when state is stopping" do
        processor.run do
          processor.instance_variable_get(:@lifecycle).stop!
          expect(processor.stopping?).to be true
        end
      end

      it "returns false when state is not stopping" do
        expect(processor.stopping?).to be false
      end
    end

    describe "#drained?" do
      it "returns true when draining and idle" do
        processor.run do
          processor.drain
          expect(processor).to be_idle
          expect(processor.drained?).to be true
        end
      end

      it "returns false when draining but not idle" do
        stub_request(:get, "https://api.example.com/users")
          .to_return do
            sleep(0.1) # Delay response to keep request in-flight
            {status: 200, body: "response body", headers: {}}
          end

        processor.run do
          processor.enqueue(mock_request)
          processor.wait_for_processing(timeout: 0.5)
          processor.drain

          # Should be draining but not idle (request still in flight)
          expect(processor.draining?).to be true
          expect(processor.drained?).to be false
        end
      end

      it "returns false when not draining" do
        processor.run do
          expect(processor.drained?).to be false
        end
      end
    end
  end

  describe "state transitions" do
    it "transitions from stopped to running" do
      expect(processor.state).to eq(:stopped)
      processor.run do
        expect(processor.state).to eq(:running)
      end
    end

    it "transitions from running to draining" do
      processor.run do
        expect(processor.state).to eq(:running)
        processor.drain
        expect(processor.state).to eq(:draining)
      end
    end

    it "transitions from running to stopping to stopped" do
      processor.start
      expect(processor.state).to eq(:running)
      processor.stop
      expect(processor.state).to eq(:stopped)
    end

    it "transitions from draining to stopping to stopped" do
      processor.start
      processor.drain
      expect(processor.state).to eq(:draining)
      processor.stop
      expect(processor.state).to eq(:stopped)
    end

    it "allows restart after stop" do
      processor.start
      expect(processor.state).to eq(:running)

      processor.stop
      expect(processor.state).to eq(:stopped)

      processor.start
      expect(processor.state).to eq(:running)

      processor.stop
    end
  end

  describe "thread safety" do
    around do |example|
      # Disable WebMock entirely for this test to work around Async fiber limitations
      # WebMock stubs don't reliably propagate to Async fibers due to thread-local storage
      WebMock.reset!
      WebMock.allow_net_connect!

      example.run
    ensure
      WebMock.reset!
      WebMock.disable_net_connect!(allow_localhost: true)
    end

    it "handles concurrent enqueues safely" do
      # Stub the HTTP request - this will be used when the fiber context allows
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "{}", headers: {"Content-Type" => "application/json"})

      # Mock dequeue_request to prevent processing
      count = 0
      mutex = Mutex.new

      allow(processor).to receive(:dequeue_request) do |**_args|
        mutex.synchronize { count += 1 }
        nil # Return nil to prevent processing
      end

      processor.run do
        threads = 10.times.map do |_i|
          Thread.new do
            10.times do |_j|
              request = create_request_task
              processor.enqueue(request)
            end
          end
        end

        threads.each(&:join)

        # Wait for all 100 requests to be dequeued
        sleep(0.001) until count >= 100

        queue = processor.instance_variable_get(:@queue)
        # Queue should have 100 items or be processing them
        expect(queue.size + count).to be >= 100
      end
    end

    it "handles concurrent state reads safely" do
      processor.run do
        results = []
        threads = 10.times.map do
          Thread.new do
            100.times do
              results << processor.state
            end
          end
        end

        threads.each(&:join)

        expect(results).to all(satisfy { |state| PatientHttp::LifecycleManager::STATES.include?(state) })
        expect(results.size).to eq(1000)
      end
    end
  end

  describe "error handling" do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:config) do
      PatientHttp::Configuration.new(logger: logger)
    end
    let(:processor_with_logger) { described_class.new(config) }

    it "logs errors from the reactor loop" do
      # Force an error in the reactor by making dequeue_request raise
      allow(processor_with_logger).to receive(:dequeue_request).and_raise(StandardError.new("Test error"))

      # Drive start/stop directly rather than via #run: the reactor crashes on
      # the first dequeue and never reaches the running state, so #run's
      # wait_for_running would block for its full 5s timeout.
      processor_with_logger.start
      begin
        # Wait for the error to be logged (the reactor crashes on first dequeue).
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
        Thread.pass until log_output.string.match?(/Test error/) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        expect(log_output.string).to match(/Test error/)
      ensure
        processor_with_logger.stop(timeout: 0)
      end
    end

    it "recovers from errors and stops gracefully" do
      allow(processor_with_logger).to receive(:dequeue_request).and_raise(StandardError.new("Test error"))

      processor_with_logger.start

      processor_with_logger.stop
      expect(processor_with_logger).to be_stopped
    end
  end

  describe "reactor loop" do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:config) do
      PatientHttp::Configuration.new(
        logger: logger,
        max_connections: 2
      )
    end

    before do
      stub_request(:get, "https://api.example.com/users").to_return(status: 200, body: "response", headers: {})
    end

    it "consumes requests from the queue" do
      requests_processed = []
      signal_queue = Queue.new
      processor = described_class.new(config)
      processor.testing_callback = lambda { |task|
        requests_processed << task
        signal_queue << task
      }
      processor.run do
        request1 = create_request_task
        request2 = create_request_task

        processor.enqueue(request1)
        processor.enqueue(request2)

        # Wait for both requests to be processed
        2.times { signal_queue.pop }

        expect(requests_processed).to include(request1, request2)
      end
    end

    it "spawns new fibers for each request" do
      fiber_count = Concurrent::AtomicFixnum.new(0)
      signal_queue = Queue.new
      processor = described_class.new(config)
      processor.testing_callback = lambda { |task|
        fiber_count.increment
        signal_queue << task
      }
      processor.run do
        # Enqueue requests up to max_connections
        config.max_connections.times { |_i| processor.enqueue(create_request_task) }

        # Wait for all to complete
        config.max_connections.times { signal_queue.pop }

        expect(fiber_count.value).to eq(config.max_connections)
      end
    end

    it "logs reactor start and stop" do
      processor.start

      expect(log_output.string).to include("[PatientHttp] Processor started")

      processor.stop

      expect(log_output.string).to include("[PatientHttp] Processor stopped")
    end

    it "breaks loop when stopping" do
      # Track if reactor loop is running
      loop_running = Concurrent::AtomicBoolean.new(false)

      # Override dequeue_request to signal when loop is active
      allow(processor).to receive(:dequeue_request) do |**_args|
        loop_running.make_true
        sleep(0.01) # Brief pause to allow shutdown check
        nil
      end

      processor.start
      processor.wait_for_running

      # Stop the processor
      processor.stop(timeout: 0)

      # Should have stopped
      expect(processor).to be_stopped
    end

    it "handles Async::Stop gracefully" do
      processor.start

      processor.stop

      # The log may or may not contain the stop signal message depending on timing
      # Just verify it stopped gracefully
      expect(processor).to be_stopped
    end

    it "checks capacity before spawning fibers when at limit" do
      processor = described_class.new(config)
      processor.run do
        # Directly populate inflight_requests to simulate at-capacity state
        lock = processor.instance_variable_get(:@tasks_lock)
        inflight = processor.instance_variable_get(:@inflight_requests)
        lock.synchronize do
          config.max_connections.times do |i|
            inflight["fake-#{i}"] = create_request_task
          end
        end

        expect do
          processor.enqueue(create_request_task)
        end.to raise_error(PatientHttp::MaxCapacityError,
          /already at max capacity/)

        # Clean up fake entries so processor can stop cleanly
        lock.synchronize { inflight.clear }
      end
    end
  end

  describe "HTTP execution" do
    include Async::RSpec::Reactor

    let(:client) { instance_double(Async::HTTP::Client) }
    let(:async_response) { instance_double(Async::HTTP::Protocol::Response) }
    let(:response_body) { instance_double(Protocol::HTTP::Body::Buffered) }

    around do |example|
      processor.run do
        example.run
      end
    end

    # Helper to create a headers double that supports [] access
    def stub_headers(headers_hash = {})
      headers_double = double("Headers")
      allow(headers_double).to receive(:[]) do |key|
        headers_hash[key]
      end
      allow(headers_double).to receive(:to_h).and_return(headers_hash)
      headers_double
    end

    # Helper to stub async_response with a body
    def stub_async_response_body(body_content)
      allow(async_response).to receive(:body).and_return(response_body)
      # Support both .each (new) and .join (old) for compatibility
      allow(response_body).to receive(:each).and_yield(body_content)
      allow(response_body).to receive(:join).and_return(body_content)
      allow(async_response).to receive(:close)
    end

    it "builds response with all attributes" do
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 201, body: "response body", headers: {"X-Custom" => "value"})

      captured_response = nil
      allow(processor).to receive(:handle_completion) do |_req, resp|
        captured_response = resp
      end

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(captured_response.status).to eq(201)
      expect(captured_response.body).to eq("response body")
      expect(captured_response.headers["X-Custom"]).to eq("value")
      expect(captured_response.request_id).to eq(mock_request.id)
      expect(captured_response.duration).to be_a(Float)
    end

    it "calls handle_completion on successful response" do
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "response body", headers: {})

      expect(processor).to receive(:handle_completion).with(mock_request, kind_of(PatientHttp::Response))

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    # Parameterized error handling tests
    [
      {error_class: Async::TimeoutError, error_message: "Request timed out", error_type: :timeout},
      {error_class: OpenSSL::SSL::SSLError, error_message: "SSL error", error_type: :ssl},
      {error_class: Errno::ECONNREFUSED, error_message: "Connection refused", error_type: :connection},
      {error_class: StandardError, error_message: "Unknown error", error_type: :unknown}
    ].each do |test_case|
      it "handles #{test_case[:error_type]} errors" do
        stub_request(:get, "https://api.example.com/users")
          .to_raise(test_case[:error_class].new(test_case[:error_message]))

        expect(processor).to receive(:handle_error).with(mock_request, kind_of(test_case[:error_class]))

        Async do
          processor.send(:process_request, mock_request)
        end
      end
    end

    it "raises ResponseTooLargeError when content-length exceeds max" do
      # Create a body that is larger than max_response_size (1MB)
      large_body = "x" * 1_048_577  # Just over 1MB
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: large_body, headers: {})

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(PatientHttp::ResponseTooLargeError))

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "raises ResponseTooLargeError when body size exceeds max during read" do
      large_chunk = "x" * 6_000_000
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: large_chunk + large_chunk, headers: {})

      # Simulate large body chunks that exceed max_response_size
      large_chunk = "x" * 6_000_000
      allow(response_body).to receive(:each).and_yield(large_chunk).and_yield(large_chunk)

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(PatientHttp::ResponseTooLargeError))

      processor.run do
        Async do
          processor.send(:process_request, mock_request)
        end
      end
    end

    it "handles ResponseTooLargeError correctly" do
      # Create a body that is larger than max_response_size (1MB)
      large_body = "x" * 1_048_577  # Just over 1MB
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: large_body, headers: {})

      expect(processor).to receive(:handle_error).with(mock_request, kind_of(PatientHttp::ResponseTooLargeError))

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "cleans up Fiber storage in ensure block" do
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "response body", headers: {})

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(Fiber[:current_request]).to be_nil
    end

    it "cleans up Fiber storage even on error" do
      stub_request(:get, "https://api.example.com/users")
        .to_raise(StandardError.new("Error"))

      Async do
        processor.send(:process_request, mock_request)
      end

      expect(Fiber[:current_request]).to be_nil
    end

    it "builds HTTP request with body when present" do
      request_with_body = create_request_task(
        method: :post,
        url: "https://api.example.com/users",
        headers: {"Content-Type" => "application/json"},
        body: '{"name":"John"}',
        timeout: 30
      )

      stub_request(:post, "https://api.example.com/users")
        .with(body: '{"name":"John"}', headers: {"Content-Type" => "application/json"})
        .to_return(status: 201, body: "response body", headers: {})

      Async do
        processor.send(:process_request, request_with_body)
      end

      # Verify that webmock received the request with the body
      expect(WebMock).to have_requested(:post, "https://api.example.com/users")
        .with(body: '{"name":"John"}')
    end

    it "uses connection pool with_client" do
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "response body", headers: {})

      Async do
        processor.send(:process_request, mock_request)
      end
    end

    it "uses http_client to make request" do
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "response body", headers: {})

      Async do
        processor.send(:process_request, mock_request)
      end

      # Verify that webmock received the request
      expect(WebMock).to have_requested(:get, "https://api.example.com/users")
    end

    it "uses request_timeout from configuration when request timeout is nil" do
      # Create request with nil timeout to use default
      request_without_timeout = create_request_task(timeout: nil)

      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "response body", headers: {})

      # Capture the timeout value by wrapping with_timeout on the instance
      timeout_value = nil
      original_process_request = processor.method(:process_request)
      allow(processor).to receive(:process_request) do |req|
        # Run in Async context
        Async do |task|
          original_with_timeout = task.method(:with_timeout)
          allow(task).to receive(:with_timeout) do |timeout, &block|
            timeout_value = timeout
            original_with_timeout.call(timeout, &block)
          end
          original_process_request.call(req)
        end.wait
      end

      processor.send(:process_request, request_without_timeout)

      expect(timeout_value).to eq(config.request_timeout)
    end

    it "uses request timeout when provided" do
      request_with_timeout = create_request_task(
        timeout: 45.0
      )

      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "response body", headers: {})

      # Capture the timeout value by wrapping with_timeout on the instance
      timeout_value = nil
      original_process_request = processor.method(:process_request)
      allow(processor).to receive(:process_request) do |req|
        # Run in Async context
        Async do |task|
          original_with_timeout = task.method(:with_timeout)
          allow(task).to receive(:with_timeout) do |timeout, &block|
            timeout_value = timeout
            original_with_timeout.call(timeout, &block)
          end
          original_process_request.call(req)
        end.wait
      end

      processor.send(:process_request, request_with_timeout)

      expect(timeout_value).to eq(45.0)
    end
  end

  describe "success handling" do
    let(:response_hash) do
      {
        "status" => 200,
        "headers" => {"content-type" => "application/json"},
        "body" => {"encoding" => "text", "value" => '{"result":"ok"}'},
        "protocol" => "HTTP/2",
        "request_id" => "req-123",
        "url" => "https://api.example.com/users",
        "method" => "GET",
        "duration" => 0.5,
        "callback_args" => {"id" => 1, "arg" => "test_arg"}
      }
    end

    let(:response) { PatientHttp::Response.load(response_hash) }

    around do |example|
      processor.run do
        example.run
      end
    end

    it "calls task_handler on_complete with response" do
      processor.send(:handle_completion, mock_request, response)
      expect(mock_request.task_handler.completions.size).to eq(1)
    end

    it "passes response and callback to task_handler on_complete" do
      processor.send(:handle_completion, mock_request, response)
      expect(mock_request.task_handler.completions.size).to eq(1)
      completion = mock_request.task_handler.completions.last
      expect(completion[:response]).to be_a(PatientHttp::Response)
      expect(completion[:response].status).to eq(200)
      expect(completion[:response].callback_args.as_json).to eq({"id" => 1, "arg" => "test_arg"})
      expect(completion[:callback]).to eq("TestCallback")
    end

    it "logs success at debug level" do
      log_output = StringIO.new
      logger = Logger.new(log_output)
      logger.level = Logger::DEBUG

      # Create a new processor with a logger in the config
      config_with_logger = PatientHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)
      processor_with_logger.run do
        processor_with_logger.send(:handle_completion, mock_request, response)
      end

      expect(log_output.string).to match(
        /DEBUG.*\[PatientHttp\] Request #{Regexp.escape(mock_request.id)} succeeded with status 200.*enqueued callback TestCallback/
      )
    end
  end

  describe "error handling" do
    around do |example|
      processor.run do
        example.run
      end
    end

    it "builds Error from exception" do
      exception = Async::TimeoutError.new("Request timed out")

      processor.send(:handle_error, mock_request, exception)

      expect(mock_request.task_handler.errors.size).to eq(1)
      error = mock_request.task_handler.errors.last[:error]
      expect(error.error_type).to eq(:timeout)
      expect(error.error_class).to eq(Async::TimeoutError)
      expect(error.message).to eq("Request timed out")
      expect(error.request_id).to eq(mock_request.id)
    end

    it "passes error and callback to task_handler on_error" do
      exception = StandardError.new("Test error")

      processor.send(:handle_error, mock_request, exception)

      expect(mock_request.task_handler.errors.size).to eq(1)
      error_entry = mock_request.task_handler.errors.last
      error = error_entry[:error]
      expect(error).to be_a(PatientHttp::RequestError)
      expect(error.callback_args.as_json).to eq({"id" => 1, "arg" => "test_arg"})
      expect(error_entry[:callback]).to eq("TestCallback")
    end

    it "handles timeout errors" do
      exception = Async::TimeoutError.new("Request timed out")

      processor.send(:handle_error, mock_request, exception)

      expect(mock_request.task_handler.errors.size).to eq(1)
      error = mock_request.task_handler.errors.last[:error]
      expect(error.error_type).to eq(:timeout)
    end

    it "handles connection errors" do
      exception = Errno::ECONNREFUSED.new("Connection refused")

      processor.send(:handle_error, mock_request, exception)

      expect(mock_request.task_handler.errors.size).to eq(1)
      error = mock_request.task_handler.errors.last[:error]
      expect(error.error_type).to eq(:connection)
    end

    it "handles SSL errors" do
      exception = OpenSSL::SSL::SSLError.new("SSL error")

      processor.send(:handle_error, mock_request, exception)

      expect(mock_request.task_handler.errors.size).to eq(1)
      error = mock_request.task_handler.errors.last[:error]
      expect(error.error_type).to eq(:ssl)
    end

    it "handles unknown errors" do
      exception = StandardError.new("Unknown error")

      processor.run do
        processor.send(:handle_error, mock_request, exception)
      end

      expect(mock_request.task_handler.errors.size).to eq(1)
      error = mock_request.task_handler.errors.last[:error]
      expect(error.error_type).to eq(:unknown)
    end

    it "logs error at warn level" do
      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = PatientHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)
      processor_with_logger.run do
        exception = Async::TimeoutError.new("Request timed out")
        processor_with_logger.send(:handle_error, mock_request, exception)
      end

      expect(log_output.string).to match(/WARN.*\[PatientHttp\] Request #{Regexp.escape(mock_request.id)} failed with Async::TimeoutError/)
      expect(log_output.string).to match(/enqueued callback TestCallback/)
    end

    it "handles errors during task_handler on_error gracefully", :disable_testing_mode do
      # Make the task handler's on_error raise
      allow(mock_request.task_handler).to receive(:on_error).and_raise(StandardError.new("Handler error"))

      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = PatientHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)
      processor_with_logger.start

      exception = StandardError.new("Test error")

      expect do
        processor_with_logger.send(:handle_error, mock_request, exception)
      end.not_to raise_error

      processor_with_logger.stop
      expect(log_output.string).to match(/\[PatientHttp\] Failed to enqueue error worker for request #{Regexp.escape(mock_request.id)}/)
    end

    it "includes backtrace in error" do
      exception = StandardError.new("Test error")
      exception.set_backtrace(["line 1", "line 2", "line 3"])

      processor.send(:handle_error, mock_request, exception)

      expect(mock_request.task_handler.errors.size).to eq(1)
      error = mock_request.task_handler.errors.last[:error]
      expect(error.backtrace).to eq(["line 1", "line 2", "line 3"])
    end
  end

  describe "graceful shutdown", :disable_testing_mode do
    let(:mock_client) { double("Async::HTTP::Client") }
    let(:mock_headers) { double("Headers", to_h: {"Content-Type" => "application/json"}) }
    let(:mock_async_response) do
      double("Async::HTTP::Response",
        status: 200,
        headers: mock_headers,
        protocol: "HTTP/1.1")
    end

    it "completes all in-flight requests during clean shutdown" do
      # Set up HTTP client mock
      allow(Async::HTTP::Client).to receive(:new).and_return(mock_client)
      allow(mock_client).to receive(:call).and_return(mock_async_response)
      allow(mock_client).to receive(:close)
      allow(mock_async_response).to receive(:body).and_return(StringIO.new("response body"))

      processor.start

      # Enqueue a request
      request = create_request_task(
        jid: "jid-clean"
      )
      processor.enqueue(request)

      # Stop with timeout
      processor.stop(timeout: 2)

      # Should have completed the request (still no in-flight after stop)
      expect(processor.inflight_count).to eq(0)
    end

    it "re-enqueues incomplete requests when timeout expires" do
      # Set up slow HTTP response that won't complete in time
      stub_request(:get, "https://api.example.com/users")
        .to_return do
          sleep(0.2) # Simulate slow request
          {status: 200, body: "response body", headers: {}}
        end

      processor.start

      # Enqueue a request
      request = create_request_task(
        jid: "jid-timeout",
        job_args: [4, 5, 6]
      )
      processor.enqueue(request)
      processor.wait_for_processing

      # Stop with short timeout (request won't complete)
      processor.stop(timeout: 0.001)

      # Should re-enqueue the incomplete request via task_handler.retry
      retries = request.task_handler.retries
      expect(retries.size).to eq(1)
      expect(retries.first["class"]).to eq("TestWorker")
      expect(retries.first["args"]).to eq([4, 5, 6])
    end

    it "re-enqueues multiple incomplete requests" do
      # Set up slow HTTP response
      stub_request(:get, "https://api.example.com/users")
        .to_return do
          sleep(0.2) # Simulate slow request
          {status: 200, body: "response body", headers: {}}
        end

      processor.start

      # Enqueue multiple requests
      request1 = create_request_task(
        jid: "jid-multi-1",
        job_args: [10, 20]
      )
      request2 = create_request_task(
        jid: "jid-multi-2",
        job_args: [30, 40]
      )
      request3 = create_request_task(
        jid: "jid-multi-3",
        job_args: [50, 60]
      )

      processor.enqueue(request1)
      processor.enqueue(request2)
      processor.enqueue(request3)

      # Wait for requests to start processing
      processor.wait_for_processing

      # Stop with short timeout
      processor.stop(timeout: 0.001)

      # Should re-enqueue all incomplete requests via task_handler.retry
      all_retries = [request1, request2, request3].flat_map { |r| r.task_handler.retries }
      expect(all_retries.size).to eq(3)
      retry_args = all_retries.map { |r| r["args"] }
      expect(retry_args).to contain_exactly([10, 20], [30, 40], [50, 60])
    end

    it "logs re-enqueued requests at info level" do
      # Set up slow HTTP response
      stub_request(:get, "https://api.example.com/users")
        .to_return do
          sleep(0.2) # Simulate slow request
          {status: 200, body: "response body", headers: {}}
        end

      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = PatientHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)

      processor_with_logger.start

      # Enqueue a request
      request = create_request_task
      processor_with_logger.enqueue(request)

      # Wait for request to start processing
      processor_with_logger.wait_for_processing

      # Stop with short timeout
      processor_with_logger.stop(timeout: 0.001)

      # Check log output
      expect(log_output.string).to match(/\[PatientHttp\] Retrying incomplete request #{Regexp.escape(request.id)}/)
    end

    it "handles errors during re-enqueue gracefully", :disable_testing_mode do
      # Set up slow HTTP response
      stub_request(:get, "https://api.example.com/users")
        .to_return do
          sleep(0.2) # Simulate slow request
          {status: 200, body: "response body", headers: {}}
        end

      log_output = StringIO.new
      logger = Logger.new(log_output)

      config_with_logger = PatientHttp::Configuration.new(logger: logger)
      processor_with_logger = described_class.new(config_with_logger)

      processor_with_logger.start

      # Enqueue a request with a handler that raises on retry
      request = create_request_task(
        job_args: [7, 8, 9]
      )
      allow(request.task_handler).to receive(:retry).and_raise(StandardError.new("Enqueue failed"))
      processor_with_logger.enqueue(request)
      processor_with_logger.wait_for_processing

      # Stop should not raise error
      expect do
        processor_with_logger.stop(timeout: 0.001)
      end.not_to raise_error

      # Check error was logged
      expect(log_output.string).to match(/\[PatientHttp\] Failed to re-enqueue request #{Regexp.escape(request.id)}/)
    end
  end

  describe "review regression fixes" do
    # Observer that counts start / request_start / request_end callbacks.
    let(:counting_observer_class) do
      Class.new(PatientHttp::ProcessorObserver) do
        attr_reader :starts, :stops, :request_starts, :request_ends

        def initialize
          @starts = Concurrent::AtomicFixnum.new(0)
          @stops = Concurrent::AtomicFixnum.new(0)
          @request_starts = Concurrent::AtomicFixnum.new(0)
          @request_ends = Concurrent::AtomicFixnum.new(0)
        end

        def start
          @starts.increment
        end

        def stop
          @stops.increment
        end

        def request_start(_task)
          @request_starts.increment
        end

        def request_end(_task)
          @request_ends.increment
        end
      end
    end

    describe "self-cleaning reactor teardown" do
      # Route the intentional reactor-crash error to a StringIO instead of the
      # default stderr logger so it does not pollute the test output.
      let(:config) { PatientHttp::Configuration.new(logger: Logger.new(StringIO.new)) }

      it "re-enqueues tracked tasks if the reactor exits without stop()" do
        orphan = create_request_task

        # Seed a tracked task, then crash the reactor's dequeue loop so it
        # exits without a stop() call.
        processor.instance_variable_get(:@tasks_lock).synchronize do
          processor.instance_variable_get(:@pending_tasks)[orphan.id] = orphan
        end
        allow(processor).to receive(:dequeue_request).and_raise(StandardError.new("reactor boom"))

        processor.start

        # Wait for the teardown to re-enqueue the orphaned task.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        Thread.pass until orphan.task_handler.retries.any? || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        expect(orphan.task_handler.retries.size).to eq(1)
        expect(processor.inflight_count).to eq(0)
        expect(processor.instance_variable_get(:@pending_tasks)).to be_empty
        expect(processor).to be_stopped
      end
    end

    describe "observer request_start/request_end balance" do
      it "does not emit request_end for tasks retried without starting" do
        observer = counting_observer_class.new
        # Never let the reactor consume the queue, so the enqueued task is
        # retried straight from the queue without ever starting.
        allow(processor).to receive(:dequeue_request) { |**_args| nil }

        processor.start
        processor.observe(observer)
        processor.enqueue(create_request_task)
        processor.stop(timeout: 0)

        expect(observer.request_starts.value).to eq(0)
        expect(observer.request_ends.value).to eq(0)
      end

      it "keeps request_start/request_end balanced when a started request is retried" do
        stub_request(:get, "https://api.example.com/users")
          .to_return do
            sleep(0.2) # keep the request in-flight past the shutdown deadline
            {status: 200, body: "", headers: {}}
          end

        observer = counting_observer_class.new
        processor.start
        processor.observe(observer)
        processor.enqueue(create_request_task)
        processor.wait_for_processing
        processor.stop(timeout: 0.001)

        expect(observer.request_starts.value).to eq(1)
        expect(observer.request_ends.value).to eq(observer.request_starts.value)
      end
    end

    describe "atomic redirect handoff" do
      it "never exposes an idle gap while handing off a redirect" do
        stub_request(:get, "https://api.example.com/start")
          .to_return(status: 302, headers: {"Location" => "https://api.example.com/finish"})
        stub_request(:get, "https://api.example.com/finish")
          .to_return(status: 200, body: "ok", headers: {})

        processor.start
        request = create_request_task(url: "https://api.example.com/start")

        idle_during_handoff = Concurrent::AtomicBoolean.new(false)
        # redirect_task is built before the original is removed from in-flight,
        # so the processor must never look idle at this point.
        allow(request).to receive(:redirect_task).and_wrap_original do |original, **kwargs|
          idle_during_handoff.make_true if processor.idle?
          original.call(**kwargs)
        end

        processor.enqueue(request)
        processor.wait_for_idle(timeout: 2)

        expect(idle_during_handoff.value).to be(false)
        expect(request.task_handler.completions.size).to eq(1)
      end
    end

    describe "observer start delivery" do
      it "notifies an observer registered before start exactly once" do
        observer = counting_observer_class.new
        processor.observe(observer)
        processor.start
        processor.wait_for_running

        expect(observer.starts.value).to eq(1)
      end

      it "notifies an observer registered while running exactly once" do
        observer = counting_observer_class.new
        processor.start
        processor.wait_for_running
        processor.observe(observer)

        expect(observer.starts.value).to eq(1)
      end
    end

    describe "testing_callback" do
      it "does not fire for tasks discarded during shutdown" do
        stub_request(:get, "https://api.example.com/users")
          .to_return do
            sleep(0.2) # keep the request in-flight past the shutdown deadline
            {status: 200, body: "", headers: {}}
          end

        called_ids = Concurrent::Array.new
        processor.testing_callback = ->(task) { called_ids << task.id }

        processor.start
        request = create_request_task
        processor.enqueue(request)
        processor.wait_for_processing
        processor.stop(timeout: 0.001)

        expect(called_ids).not_to include(request.id)
        expect(request.task_handler.retries.size).to eq(1)
      end
    end

    describe "completion callback failures", :disable_testing_mode do
      let(:log_output) { StringIO.new }
      let(:config) { PatientHttp::Configuration.new(logger: Logger.new(log_output)) }

      it "logs the failure and still finishes the task" do
        stub_request(:get, "https://api.example.com/users")
          .to_return(status: 200, body: "", headers: {})

        observer = counting_observer_class.new
        request = create_request_task
        allow(request.task_handler).to receive(:on_complete).and_raise(StandardError.new("job system down"))

        processor.start
        processor.observe(observer)
        processor.enqueue(request)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        Thread.pass until observer.request_ends.value == 1 || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        expect(log_output.string).to match(/Failed to enqueue completion callback for request #{Regexp.escape(request.id)}/)
        expect(observer.request_starts.value).to eq(1)
        expect(observer.request_ends.value).to eq(1)
        expect(processor.inflight_count).to eq(0)
      end
    end

    describe "stop from the reactor thread" do
      it "stops cleanly when called from a task callback" do
        stub_request(:get, "https://api.example.com/users")
          .to_return(status: 200, body: "", headers: {})

        observer = counting_observer_class.new
        request = create_request_task
        stop_error = nil
        allow(request.task_handler).to receive(:on_complete) do
          processor.stop(timeout: 0)
        rescue => e
          stop_error = e
        end

        processor.start
        processor.observe(observer)
        processor.enqueue(request)

        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        Thread.pass until (processor.stopped? && observer.stops.value == 1) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        expect(stop_error).to be_nil
        expect(processor).to be_stopped
        expect(observer.stops.value).to eq(1)
      end
    end
  end

  describe "lifecycle race fixes" do
    it "assigns a fresh reactor generation on each start" do
      expect(processor.instance_variable_get(:@reactor_generation)).to eq(0)

      processor.start
      expect(processor.instance_variable_get(:@reactor_generation)).to eq(1)

      processor.stop(timeout: 0)
      processor.start
      expect(processor.instance_variable_get(:@reactor_generation)).to eq(2)
    end

    it "never leaves the processor running with a dead reactor under concurrent start/stop" do
      30.times do
        starter = Thread.new { processor.start }
        stopper = Thread.new { processor.stop(timeout: 0) }
        [starter, stopper].each(&:join)

        # start and stop are serialized, so the observed state is always
        # consistent: if it reports running, a live reactor backs it.
        if processor.running?
          reactor = processor.instance_variable_get(:@reactor_thread)
          expect(reactor).to be_a(Thread)
          expect(reactor).to be_alive
        end

        processor.stop(timeout: 0) # normalize before the next iteration
      end
    end

    it "wakes a stop() blocked in its idle-wait when tracked tasks are drained" do
      lock = processor.instance_variable_get(:@tasks_lock)
      cond = processor.instance_variable_get(:@idle_condition)
      # A tracked task keeps the idle-wait from returning on its own.
      processor.instance_variable_get(:@inflight_requests)["stuck"] = create_request_task

      woke = Concurrent::AtomicBoolean.new(false)
      waiter = Thread.new do
        lock.synchronize { cond.wait(lock, 5) } # long timeout; must be woken well before it
        woke.make_true
      end

      # Ensure the waiter is actually parked inside cond.wait (lock released).
      Thread.pass until waiter.status == "sleep"
      sleep(0.02)

      # Draining the tracking hashes must signal the idle condition; without the
      # broadcast the waiter would sleep until its 5s timeout.
      processor.send(:drain_tracked_tasks)
      joined = waiter.join(1)

      expect(joined).not_to be_nil
      expect(woke.value).to be(true)
    end
  end

  describe "redirect handling" do
    it "follows 302 redirect with Location header" do
      stub_request(:get, "https://api.example.com/old-path")
        .to_return(status: 302, headers: {"Location" => "https://api.example.com/new-path"})

      stub_request(:get, "https://api.example.com/new-path")
        .to_return(status: 200, body: "final response", headers: {})

      processor.start

      request = create_request_task(url: "https://api.example.com/old-path")
      processor.enqueue(request)
      processor.wait_for_idle(timeout: 2)

      expect(request.task_handler.completions.size).to eq(1)
      response = request.task_handler.completions.first[:response]
      expect(response.status).to eq(200)
      expect(response.url).to eq("https://api.example.com/new-path")
      expect(response.redirects).to eq(["https://api.example.com/old-path"])
    end

    it "follows redirect chain" do
      processor.start
      request = create_request_task(url: "https://api.example.com/1")

      stub_request(:get, "https://api.example.com/1")
        .with(headers: {"x-request-id" => request.id})
        .to_return(status: 301, headers: {"Location" => "https://api.example.com/2"})

      stub_request(:get, "https://api.example.com/2")
        .with(headers: {"x-request-id" => "#{request.id}/2"})
        .to_return(status: 302, headers: {"Location" => "https://api.example.com/3"})

      stub_request(:get, "https://api.example.com/3")
        .with(headers: {"x-request-id" => "#{request.id}/3"})
        .to_return(status: 200, body: "final", headers: {})

      processor.enqueue(request)
      processor.wait_for_idle(timeout: 2)

      expect(request.task_handler.completions.size).to eq(1)
      response = request.task_handler.completions.first[:response]
      expect(response.status).to eq(200)
      expect(response.url).to eq("https://api.example.com/3")
      expect(response.redirects).to eq([
        "https://api.example.com/1",
        "https://api.example.com/2"
      ])
      expect(response.request_id).to eq(request.id)
    end

    it "converts POST to GET on 302 redirect" do
      stub_request(:post, "https://api.example.com/submit")
        .to_return(status: 302, headers: {"Location" => "https://api.example.com/result"})

      stub_request(:get, "https://api.example.com/result")
        .to_return(status: 200, body: "success", headers: {})

      processor.start

      request = create_request_task(method: :post, url: "https://api.example.com/submit", body: '{"data":"test"}')
      processor.enqueue(request)
      processor.wait_for_idle(timeout: 2)

      expect(request.task_handler.completions.size).to eq(1)
      response = request.task_handler.completions.first[:response]
      expect(response.status).to eq(200)
      expect(response.http_method).to eq(:get)
    end

    it "preserves POST method on 307 redirect" do
      stub_request(:post, "https://api.example.com/submit")
        .to_return(status: 307, headers: {"Location" => "https://api.example.com/new-submit"})

      stub_request(:post, "https://api.example.com/new-submit")
        .with(body: '{"data":"test"}')
        .to_return(status: 200, body: "success", headers: {})

      processor.start

      request = create_request_task(method: :post, url: "https://api.example.com/submit", body: '{"data":"test"}')
      processor.enqueue(request)
      processor.wait_for_idle(timeout: 2)

      expect(request.task_handler.completions.size).to eq(1)
      response = request.task_handler.completions.first[:response]
      expect(response.status).to eq(200)
      expect(response.http_method).to eq(:post)
    end

    it "raises TooManyRedirectsError when max redirects exceeded" do
      # Set up redirect loop that exceeds max
      (1..10).each do |i|
        stub_request(:get, "https://api.example.com/#{i}")
          .to_return(status: 302, headers: {"Location" => "https://api.example.com/#{i + 1}"})
      end

      processor.start

      # Use max_redirects of 3
      request = PatientHttp::Request.new(:get, "https://api.example.com/1", max_redirects: 3)
      handler = TestTaskHandler.new({"class" => "TestWorker", "jid" => SecureRandom.uuid, "args" => []})
      task = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler,
        callback: TestCallback
      )
      processor.enqueue(task)
      processor.wait_for_idle(timeout: 2)

      expect(handler.errors.size).to eq(1)
      error = handler.errors.first[:error]
      expect(error).to be_a(PatientHttp::TooManyRedirectsError)
      expect(error.redirects.size).to eq(4) # original + 3 redirects
    end

    it "raises RecursiveRedirectError on redirect loop" do
      stub_request(:get, "https://api.example.com/a")
        .to_return(status: 302, headers: {"Location" => "https://api.example.com/b"})

      stub_request(:get, "https://api.example.com/b")
        .to_return(status: 302, headers: {"Location" => "https://api.example.com/a"})

      processor.start

      request = create_request_task(url: "https://api.example.com/a")
      processor.enqueue(request)
      processor.wait_for_idle(timeout: 2)

      expect(request.task_handler.errors.size).to eq(1)
      error = request.task_handler.errors.first[:error]
      expect(error).to be_a(PatientHttp::RecursiveRedirectError)
      expect(error.url).to eq("https://api.example.com/a")
    end

    it "does not follow redirect when max_redirects is 0" do
      stub_request(:get, "https://api.example.com/old")
        .to_return(status: 302, headers: {"Location" => "https://api.example.com/new"})

      processor.start

      request = PatientHttp::Request.new(:get, "https://api.example.com/old", max_redirects: 0)
      handler = TestTaskHandler.new({"class" => "TestWorker", "jid" => SecureRandom.uuid, "args" => []})
      task = PatientHttp::RequestTask.new(
        request: request,
        task_handler: handler,
        callback: TestCallback
      )
      processor.enqueue(task)
      processor.wait_for_idle(timeout: 2)

      expect(handler.completions.size).to eq(1)
      response = handler.completions.first[:response]
      expect(response.status).to eq(302)
      expect(response.redirects).to eq([])
    end

    it "handles relative redirect URLs" do
      stub_request(:get, "https://api.example.com/path/old")
        .to_return(status: 302, headers: {"Location" => "/path/new"})

      stub_request(:get, "https://api.example.com/path/new")
        .to_return(status: 200, body: "success", headers: {})

      processor.start

      request = create_request_task(url: "https://api.example.com/path/old")
      processor.enqueue(request)
      processor.wait_for_idle(timeout: 2)

      expect(request.task_handler.completions.size).to eq(1)
      response = request.task_handler.completions.first[:response]
      expect(response.status).to eq(200)
      expect(response.url).to eq("https://api.example.com/path/new")
    end

    it "does not follow redirect without Location header" do
      stub_request(:get, "https://api.example.com/broken")
        .to_return(status: 302, headers: {})

      processor.start

      request = create_request_task(url: "https://api.example.com/broken")
      processor.enqueue(request)
      processor.wait_for_idle(timeout: 2)

      expect(request.task_handler.completions.size).to eq(1)
      response = request.task_handler.completions.first[:response]
      expect(response.status).to eq(302)
      expect(response.redirects).to eq([])
    end

    it "preserves callback_args through redirect chain" do
      stub_request(:get, "https://api.example.com/1")
        .to_return(status: 302, headers: {"Location" => "https://api.example.com/2"})

      stub_request(:get, "https://api.example.com/2")
        .to_return(status: 200, body: "success", headers: {})

      processor.start

      request = create_request_task(url: "https://api.example.com/1", callback_args: {"user_id" => 123, "action" => "fetch"})
      processor.enqueue(request)
      processor.wait_for_idle(timeout: 2)

      expect(request.task_handler.completions.size).to eq(1)
      response = request.task_handler.completions.first[:response]
      expect(response.callback_args.as_json).to eq({"user_id" => 123, "action" => "fetch"})
    end
  end
end
