# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp do
  after do
    described_class.unregister_handler
  end

  describe ".register_handler" do
    it "raises when neither a callable nor a block is provided" do
      expect do
        described_class.register_handler
      end.to raise_error(ArgumentError, "Must provide a callable object or a block")
    end

    it "raises when both callable and block are provided" do
      callable = proc { |request:, callback:, callback_args: nil, raise_error_responses: nil| }

      expect do
        described_class.register_handler(callable) do |request:, callback:, callback_args: nil, raise_error_responses: nil|
          nil
        end
      end.to raise_error(ArgumentError, "Cannot provide both a callable object and a block")
    end

    it "raises when callable does not respond to call" do
      expect do
        described_class.register_handler(Object.new)
      end.to raise_error(ArgumentError, "Handler must be a callable object or a block")
    end

    it "raises when handler does not accept required keyword arguments" do
      handler = proc { |other_param: nil| }

      expect do
        described_class.register_handler(handler)
      end.to raise_error(ArgumentError,
        /Handler must accept keyword arguments: request, callback, callback_args, raise_error_responses/)
    end

    it "raises when handler is missing some required keyword arguments" do
      handler = proc { |request:, callback:| }

      expect do
        described_class.register_handler(handler)
      end.to raise_error(ArgumentError, /Missing: callback_args, raise_error_responses/)
    end

    it "accepts handlers with keyword rest parameter" do
      handler = proc { |**kwargs| }

      expect do
        described_class.register_handler(handler)
      end.not_to raise_error
    end

    it "accepts handlers with all required keyword arguments" do
      handler = proc { |request:, callback:, callback_args:, raise_error_responses:| }

      expect(described_class.register_handler(handler)).to eq(handler)
    end

    it "accepts handlers with all required keyword arguments with defaults" do
      handler = proc { |request:, callback:, callback_args: nil, raise_error_responses: nil| }

      expect(described_class.register_handler(handler)).to eq(handler)
    end

    it "raises when handler accepts positional parameters" do
      handler = proc { |context, request:, callback:, callback_args: nil, raise_error_responses: nil| }

      expect do
        described_class.register_handler(handler)
      end.to raise_error(ArgumentError, /Handler must not accept positional parameters/)
    end

    it "raises when handler has extra required keyword parameters" do
      handler = proc { |request:, callback:, callback_args:, raise_error_responses:, extra_param:| }

      expect do
        described_class.register_handler(handler)
      end.to raise_error(ArgumentError, /Handler must not have extra required keyword parameters.*Found: extra_param/)
    end

    it "accepts handlers with optional keyword parameters beyond the required ones" do
      handler = proc { |request:, callback:, callback_args: nil, raise_error_responses: nil, extra_param: nil| }

      expect(described_class.register_handler(handler)).to eq(handler)
    end

    it "registers a callable object" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      callback = "TestCallback"
      callable = proc { |request:, callback:, callback_args: nil, raise_error_responses: nil| }

      described_class.register_handler(callable)
      described_class.execute(request: request, callback: callback)
    end

    it "registers a block" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      callback = "TestCallback"
      captured_request = nil
      captured_callback = nil

      described_class.register_handler do |request:, callback:, callback_args: nil, raise_error_responses: nil|
        captured_request = request
        captured_callback = callback
      end

      described_class.execute(request: request, callback: callback)

      expect(captured_request).to be(request)
      expect(captured_callback).to eq(callback)
    end
  end

  describe ".register_handler!" do
    it "raises an error if a handler is already registered" do
      described_class.register_handler { |request:, callback:, callback_args: nil, raise_error_responses: nil| }

      expect do
        described_class.register_handler! { |request:, callback:, callback_args: nil, raise_error_responses: nil| }
      end.to raise_error(RuntimeError)
    end

    it "registers a new handler if one is not already registered" do
      handler = described_class.register_handler! { |request:, callback:, callback_args: nil, raise_error_responses: nil| }
      expect(handler).to be_a(Proc)
      described_class.unregister_handler(handler)
    end
  end

  describe ".unregister_handler" do
    it "unregisters the current handler" do
      described_class.register_handler { |request:, callback:, callback_args: nil, raise_error_responses: nil| }
      described_class.unregister_handler

      expect do
        described_class.execute(
          request: PatientHttp::Request.new(:get, "https://example.com"),
          callback: "TestCallback"
        )
      end.to raise_error(RuntimeError, /No request handler registered/)
    end

    it "only unregisters if the given handler matches the current handler" do
      current_handler = proc { |request:, callback:, callback_args: nil, raise_error_responses: nil| "current" }
      other_handler = proc { |request:, callback:, callback_args: nil, raise_error_responses: nil| "other" }

      described_class.register_handler(current_handler)
      described_class.unregister_handler(other_handler)

      result = described_class.execute(
        request: PatientHttp::Request.new(:get, "https://example.com"),
        callback: "TestCallback"
      )
      expect(result).to eq("current")
    end
  end

  describe ".execute" do
    it "raises when no handler is registered" do
      expect do
        described_class.execute(
          request: PatientHttp::Request.new(:get, "https://example.com"),
          callback: "TestCallback"
        )
      end.to raise_error(
        RuntimeError,
        "No request handler registered; you must register a PatientHttp handler before executing requests"
      )
    end

    it "calls the registered handler with keyword arguments" do
      request = PatientHttp::Request.new(:get, "https://example.com")
      callback = "TestCallback"
      captured_request = nil
      captured_callback = nil
      handler = lambda { |request:, callback:, callback_args: nil, raise_error_responses: nil|
        captured_request = request
        captured_callback = callback
      }

      described_class.register_handler(handler)

      described_class.execute(request: request, callback: callback)
      expect(captured_request).to be(request)
      expect(captured_callback).to eq(callback)
    end

    it "passes callback_args and raise_error_responses to the handler" do
      captured_callback_args = nil
      captured_raise_error_responses = nil

      described_class.register_handler do |request:, callback:, callback_args: nil, raise_error_responses: nil|
        captured_callback_args = callback_args
        captured_raise_error_responses = raise_error_responses
      end

      described_class.execute(
        request: PatientHttp::Request.new(:get, "https://example.com"),
        callback: "TestCallback",
        callback_args: {"user_id" => 42},
        raise_error_responses: true
      )

      expect(captured_callback_args).to eq({"user_id" => 42})
      expect(captured_raise_error_responses).to eq(true)
    end
  end

  describe "HTTP method helpers" do
    before do
      @captured_request = nil
      @captured_callback = nil
      @captured_callback_args = nil
      @captured_raise_error_responses = nil

      described_class.register_handler do |request:, callback:, callback_args: nil, raise_error_responses: nil|
        @captured_request = request
        @captured_callback = callback
        @captured_callback_args = callback_args
        @captured_raise_error_responses = raise_error_responses
        "request-id"
      end
    end

    describe ".get" do
      it "creates a GET request and executes it" do
        result = described_class.get(
          "https://api.example.com/users/1",
          callback: "FetchCallback",
          callback_args: {"id" => 1}
        )

        expect(result).to eq("request-id")
        expect(@captured_request).to be_a(PatientHttp::Request)
        expect(@captured_request.http_method).to eq(:get)
        expect(@captured_request.url).to eq("https://api.example.com/users/1")
        expect(@captured_callback).to eq("FetchCallback")
        expect(@captured_callback_args).to eq({"id" => 1})
      end

      it "passes query params" do
        described_class.get(
          "https://api.example.com/users",
          callback: "FetchCallback",
          params: {"page" => "2"}
        )

        expect(@captured_request.url).to eq("https://api.example.com/users?page=2")
      end
    end

    describe ".post" do
      it "creates a POST request with JSON body" do
        described_class.post(
          "https://api.example.com/users",
          callback: "CreateCallback",
          json: {"name" => "John"}
        )

        expect(@captured_request.http_method).to eq(:post)
        expect(@captured_request.url).to eq("https://api.example.com/users")
        expect(@captured_request.body).to eq('{"name":"John"}')
      end

      it "creates a POST request with raw body" do
        described_class.post(
          "https://api.example.com/data",
          callback: "UploadCallback",
          body: "raw content"
        )

        expect(@captured_request.http_method).to eq(:post)
        expect(@captured_request.body).to eq("raw content")
      end
    end

    describe ".put" do
      it "creates a PUT request" do
        described_class.put(
          "https://api.example.com/users/1",
          callback: "UpdateCallback",
          json: {"name" => "Jane"}
        )

        expect(@captured_request.http_method).to eq(:put)
        expect(@captured_request.url).to eq("https://api.example.com/users/1")
      end
    end

    describe ".patch" do
      it "creates a PATCH request" do
        described_class.patch(
          "https://api.example.com/users/1",
          callback: "PatchCallback",
          json: {"name" => "Updated"}
        )

        expect(@captured_request.http_method).to eq(:patch)
        expect(@captured_request.url).to eq("https://api.example.com/users/1")
      end
    end

    describe ".delete" do
      it "creates a DELETE request" do
        described_class.delete(
          "https://api.example.com/users/1",
          callback: "DeleteCallback"
        )

        expect(@captured_request.http_method).to eq(:delete)
        expect(@captured_request.url).to eq("https://api.example.com/users/1")
      end
    end

    describe ".request" do
      it "creates a request with all options" do
        described_class.request(
          :post,
          "https://api.example.com/data",
          callback: "DataCallback",
          headers: {"X-Custom" => "header"},
          json: {"key" => "value"},
          params: {"format" => "json"},
          timeout: 120,
          raise_error_responses: true,
          callback_args: {"ref" => "abc"}
        )

        expect(@captured_request.http_method).to eq(:post)
        expect(@captured_request.url).to eq("https://api.example.com/data?format=json")
        expect(@captured_request.headers.to_h).to include("x-custom" => "header")
        expect(@captured_request.timeout).to eq(120)
        expect(@captured_callback).to eq("DataCallback")
        expect(@captured_callback_args).to eq({"ref" => "abc"})
        expect(@captured_raise_error_responses).to eq(true)
      end

      it "returns the handler's return value" do
        result = described_class.request(
          :get,
          "https://api.example.com/test",
          callback: "TestCallback"
        )

        expect(result).to eq("request-id")
      end
    end
  end

  describe "inline execution" do
    before do
      TestCallback.reset_calls!
    end

    after do
      described_class.instance_variable_set(:@module_secrets, {})
      described_class.instance_variable_set(:@default_configuration, nil)
      described_class.instance_variable_set(:@inline_configuration, nil)
    end

    describe ".inline!" do
      it "registers a handler that executes requests inline and invokes the callback" do
        stub_request(:get, "https://api.example.com/data")
          .to_return(status: 200, body: "hello", headers: {"Content-Type" => "text/plain"})

        described_class.inline!
        result = described_class.get(
          "https://api.example.com/data",
          callback: TestCallback,
          callback_args: {"id" => 1}
        )

        expect(TestCallback.error_calls).to be_empty
        expect(TestCallback.completion_calls.size).to eq(1)

        response = TestCallback.completion_calls.first
        expect(response.status).to eq(200)
        expect(response.body).to eq("hello")
        expect(response.callback_args["id"]).to eq(1)
        expect(result).to eq(response.request_id)
      end

      it "invokes the error callback when the request fails" do
        stub_request(:get, "https://api.example.com/broken").to_raise(Errno::ECONNREFUSED)

        described_class.inline!
        described_class.get("https://api.example.com/broken", callback: TestCallback)

        expect(TestCallback.completion_calls).to be_empty
        expect(TestCallback.error_calls.size).to eq(1)
        expect(TestCallback.error_calls.first).to be_a(PatientHttp::RequestError)
      end

      it "reports non-success responses as errors when raise_error_responses is set" do
        stub_request(:get, "https://api.example.com/fail").to_return(status: 500)

        described_class.inline!
        described_class.get(
          "https://api.example.com/fail",
          callback: TestCallback,
          raise_error_responses: true
        )

        expect(TestCallback.completion_calls).to be_empty
        expect(TestCallback.error_calls.size).to eq(1)
        expect(TestCallback.error_calls.first).to be_a(PatientHttp::HttpError)
      end

      it "executes requests against a provided configuration" do
        stub_request(:get, "https://api.example.com/fail").to_return(status: 500)

        config = PatientHttp::Configuration.new(raise_error_responses: true)
        described_class.inline!(config: config)
        described_class.get("https://api.example.com/fail", callback: TestCallback)

        expect(TestCallback.completion_calls).to be_empty
        expect(TestCallback.error_calls.size).to eq(1)
        expect(TestCallback.error_calls.first).to be_a(PatientHttp::HttpError)
      end

      it "supports re-entrant requests from within a callback" do
        stub_request(:get, "https://api.example.com/first").to_return(status: 200, body: "first")
        stub_request(:get, "https://api.example.com/second").to_return(status: 200, body: "second")

        reentrant_callback = Class.new do
          def on_complete(response)
            TestCallback.record_completion(response)
            if response.url.end_with?("/first")
              PatientHttp.get("https://api.example.com/second", callback: TestCallback)
            end
          end

          def on_error(error)
            TestCallback.record_error(error)
          end
        end
        stub_const("ReentrantCallback", reentrant_callback)

        described_class.inline!
        described_class.get("https://api.example.com/first", callback: "ReentrantCallback")

        expect(TestCallback.error_calls).to be_empty
        expect(TestCallback.completion_calls.map(&:body)).to contain_exactly("first", "second")
      end

      it "resolves module-level secrets on inline requests" do
        described_class.register_secret("api-key", "s3cret")
        stub = stub_request(:get, "https://api.example.com/private")
          .with(headers: {"Authorization" => "s3cret"})
          .to_return(status: 200)

        described_class.inline!
        described_class.get(
          "https://api.example.com/private",
          callback: TestCallback,
          headers: {"Authorization" => described_class.secret("api-key")}
        )

        expect(stub).to have_been_requested
        expect(TestCallback.error_calls).to be_empty
        expect(TestCallback.completion_calls.size).to eq(1)
      end
    end

    describe ".inline?" do
      it "returns false when no handler is registered" do
        expect(described_class.inline?).to be false
      end

      it "returns true when the inline handler is registered" do
        described_class.inline!
        expect(described_class.inline?).to be true
      end

      it "returns false after the handler is unregistered" do
        described_class.inline!
        described_class.unregister_handler
        expect(described_class.inline?).to be false
      end

      it "returns false when a different handler is registered" do
        described_class.inline!
        described_class.register_handler { |request:, callback:, callback_args: nil, raise_error_responses: nil| }
        expect(described_class.inline?).to be false
      end
    end

    describe ".execute_inline" do
      it "returns the request id and defaults raise_error_responses from the configuration" do
        stub_request(:get, "https://api.example.com/fail").to_return(status: 500)

        request = PatientHttp::Request.new(:get, "https://api.example.com/fail")
        result = described_class.execute_inline(request: request, callback: TestCallback)

        expect(TestCallback.error_calls).to be_empty
        expect(TestCallback.completion_calls.size).to eq(1)
        expect(TestCallback.completion_calls.first.status).to eq(500)
        expect(result).to eq(TestCallback.completion_calls.first.request_id)
      end

      it "uses the default configuration when one is set" do
        stub_request(:get, "https://api.example.com/fail").to_return(status: 500)

        described_class.default_configuration = PatientHttp::Configuration.new(raise_error_responses: true)
        request = PatientHttp::Request.new(:get, "https://api.example.com/fail")
        described_class.execute_inline(request: request, callback: TestCallback)

        expect(TestCallback.completion_calls).to be_empty
        expect(TestCallback.error_calls.size).to eq(1)
        expect(TestCallback.error_calls.first).to be_a(PatientHttp::HttpError)
      end
    end
  end

  describe "module-level secrets" do
    after do
      described_class.instance_variable_set(:@module_secrets, {})
      described_class.instance_variable_set(:@default_configuration, nil)
      described_class.instance_variable_set(:@inline_configuration, nil)
    end

    describe ".register_secret" do
      it "raises when neither a value nor a block is provided" do
        expect do
          described_class.register_secret("api-key")
        end.to raise_error(ArgumentError, "register_secret requires a value or a block")
      end

      it "raises when both a value and a block are provided" do
        expect do
          described_class.register_secret("api-key", "value") { "other" }
        end.to raise_error(ArgumentError, "register_secret accepts either a value or a block, not both")
      end

      it "applies secrets registered before a default configuration is set" do
        described_class.register_secret("api-key", "s3cret")

        config = PatientHttp::Configuration.new
        described_class.default_configuration = config

        expect(config.secret_manager.include?("api-key")).to be true
        expect(config.secret_manager.resolve("api-key")).to eq("s3cret")
      end

      it "applies secrets immediately when a default configuration is already set" do
        config = PatientHttp::Configuration.new
        described_class.default_configuration = config

        described_class.register_secret("api-key", "s3cret")

        expect(config.secret_manager.resolve("api-key")).to eq("s3cret")
      end

      it "re-applies secrets when the default configuration is replaced" do
        described_class.register_secret("api-key", "s3cret")
        described_class.default_configuration = PatientHttp::Configuration.new

        replacement = PatientHttp::Configuration.new
        described_class.default_configuration = replacement

        expect(replacement.secret_manager.resolve("api-key")).to eq("s3cret")
      end

      it "resolves block secrets lazily" do
        value = "initial"
        described_class.register_secret("api-key") { value }
        described_class.default_configuration = PatientHttp::Configuration.new

        value = "updated"

        expect(described_class.default_configuration.secret_manager.resolve("api-key")).to eq("updated")
      end
    end

    describe ".secret_registered?" do
      it "returns true for secrets registered at the module level" do
        described_class.register_secret("api-key", "s3cret")

        expect(described_class.secret_registered?("api-key")).to be true
        expect(described_class.secret_registered?(:"api-key")).to be true
      end

      it "returns true for secrets registered directly on the default configuration" do
        config = PatientHttp::Configuration.new
        config.register_secret("config-key", "s3cret")
        described_class.default_configuration = config

        expect(described_class.secret_registered?("config-key")).to be true
      end

      it "returns false when the secret is not registered anywhere" do
        described_class.default_configuration = PatientHttp::Configuration.new

        expect(described_class.secret_registered?("missing")).to be false
      end
    end

    describe ".default_configuration" do
      it "returns nil when no default configuration is set" do
        expect(described_class.default_configuration).to be_nil
      end

      it "returns the assigned configuration" do
        config = PatientHttp::Configuration.new
        described_class.default_configuration = config

        expect(described_class.default_configuration).to be(config)
      end
    end
  end
end
