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

      expect do
        described_class.register_handler(handler)
      end.not_to raise_error
    end

    it "accepts handlers with all required keyword arguments with defaults" do
      handler = proc { |request:, callback:, callback_args: nil, raise_error_responses: nil| }

      expect do
        described_class.register_handler(handler)
      end.not_to raise_error
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

      expect do
        described_class.register_handler(handler)
      end.not_to raise_error
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
end
