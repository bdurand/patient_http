# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::RequestError do
  describe ".from_exception" do
    let(:request_id) { "req_123" }
    let(:url) { "https://example.com" }

    context "with Async::TimeoutError" do
      it "classifies as :timeout" do
        exception = Async::TimeoutError.new("Request timeout")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Async::TimeoutError)
        expect(error.message).to eq("Request timeout")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:timeout)
        expect(error.duration).to eq(1.0)
      end
    end

    context "with OpenSSL::SSL::SSLError" do
      it "classifies as :ssl" do
        exception = OpenSSL::SSL::SSLError.new("SSL error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(OpenSSL::SSL::SSLError)
        expect(error.message).to eq("SSL error")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:ssl)
      end
    end

    context "with connection errors" do
      it "classifies Errno::ECONNREFUSED as :connection" do
        exception = Errno::ECONNREFUSED.new("Connection refused")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Errno::ECONNREFUSED)
        expect(error.message).to eq("Connection refused - Connection refused")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies Errno::ECONNRESET as :connection" do
        exception = Errno::ECONNRESET.new("Connection reset")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Errno::ECONNRESET)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies Errno::ECONNABORTED as :connection" do
        exception = Errno::ECONNABORTED.new("Connection aborted")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Errno::ECONNABORTED)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies Errno::EHOSTUNREACH as :connection" do
        exception = Errno::EHOSTUNREACH.new("Host unreachable")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Errno::EHOSTUNREACH)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies Errno::EPIPE as :connection" do
        exception = Errno::EPIPE.new("Broken pipe")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(Errno::EPIPE)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies SocketError as :connection" do
        exception = SocketError.new("Socket error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(SocketError)
        expect(error.error_type).to eq(:connection)
      end

      it "classifies IOError as :connection" do
        exception = IOError.new("IO error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(IOError)
        expect(error.error_type).to eq(:connection)
      end
    end

    context "with ResponseTooLargeError" do
      it "classifies as :response_too_large" do
        exception = PatientHttp::ResponseTooLargeError.new("Response too large")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(PatientHttp::ResponseTooLargeError)
        expect(error.message).to eq("Response too large")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:response_too_large)
      end
    end

    context "with unknown exception" do
      it "classifies as :unknown" do
        exception = StandardError.new("Unknown error")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.error_class).to eq(StandardError)
        expect(error.message).to eq("Unknown error")
        expect(error.request_id).to eq(request_id)
        expect(error.error_type).to eq(:unknown)
      end
    end

    context "with backtrace" do
      it "captures the backtrace" do
        exception = StandardError.new("Error with backtrace")
        exception.set_backtrace(["line 1", "line 2", "line 3"])
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)

        expect(error.backtrace).to eq(["line 1", "line 2", "line 3"])
      end
    end

    context "without backtrace" do
      it "uses empty array" do
        exception = StandardError.new("Error without backtrace")
        error = described_class.from_exception(exception, request_id: request_id, duration: 1.0, url: url,
          http_method: :get)
        expect(error.backtrace).to eq([])
      end
    end

    context "with callback_args" do
      it "includes callback_args in the error" do
        exception = StandardError.new("Test error")
        callback_args = {"user_id" => 123, "action" => "fetch"}
        error = described_class.from_exception(
          exception,
          request_id: request_id,
          duration: 1.0,
          url: url,
          http_method: :get,
          callback_args: callback_args
        )

        expect(error.callback_args).to be_a(PatientHttp::CallbackArgs)
        expect(error.callback_args[:user_id]).to eq(123)
        expect(error.callback_args[:action]).to eq("fetch")
      end

      it "defaults callback_args to empty when not provided" do
        exception = StandardError.new("Test error")
        error = described_class.from_exception(
          exception,
          request_id: request_id,
          duration: 1.0,
          url: url,
          http_method: :get
        )

        expect(error.callback_args).to be_a(PatientHttp::CallbackArgs)
        expect(error.callback_args).to be_empty
      end
    end
  end

  describe ".error_type" do
    it "classifies errors correctly" do
      expect(described_class.error_type(Async::TimeoutError.new)).to eq(:timeout)
      expect(described_class.error_type(PatientHttp::ResponseTooLargeError.new)).to eq(:response_too_large)
      expect(described_class.error_type(OpenSSL::SSL::SSLError.new)).to eq(:ssl)
      expect(described_class.error_type(Errno::ECONNREFUSED.new)).to eq(:connection)
      expect(described_class.error_type(Errno::ECONNRESET.new)).to eq(:connection)
      expect(described_class.error_type(Errno::ECONNABORTED.new)).to eq(:connection)
      expect(described_class.error_type(StandardError.new)).to eq(:unknown)
    end
  end

  describe "#as_json" do
    let(:error) do
      described_class.new(
        class_name: "StandardError",
        message: "Test error",
        backtrace: ["line 1", "line 2"],
        request_id: "req_123",
        error_type: :timeout,
        duration: 2.5,
        url: "https://example.com",
        http_method: :get,
        callback_args: {"user_id" => 123}
      )
    end

    it "returns hash with string keys" do
      hash = error.as_json

      expect(hash).to eq({
        "class_name" => "StandardError",
        "message" => "Test error",
        "backtrace" => ["line 1", "line 2"],
        "request_id" => "req_123",
        "error_type" => "timeout",
        "duration" => 2.5,
        "url" => "https://example.com",
        "http_method" => "get",
        "callback_args" => {"user_id" => 123}
      })
    end

    it "converts error_type to string" do
      expect(error.as_json["error_type"]).to be_a(String)
      expect(error.as_json["error_type"]).to eq("timeout")
    end
  end

  describe ".load" do
    let(:hash) do
      {
        "class_name" => "StandardError",
        "message" => "Test error",
        "backtrace" => ["line 1", "line 2"],
        "request_id" => "req_123",
        "error_type" => "timeout",
        "duration" => 2.5,
        "url" => "https://example.com",
        "http_method" => "get",
        "callback_args" => {"user_id" => 123}
      }
    end

    it "reconstructs error from hash" do
      error = described_class.load(hash)

      expect(error.error_class).to eq(StandardError)
      expect(error.message).to eq("Test error")
      expect(error.backtrace).to eq(["line 1", "line 2"])
      expect(error.request_id).to eq("req_123")
      expect(error.error_type).to eq(:timeout)
      expect(error.duration).to eq(2.5)
      expect(error.url).to eq("https://example.com")
      expect(error.http_method).to eq(:get)
      expect(error.callback_args[:user_id]).to eq(123)
    end

    it "converts error_type string to symbol" do
      error = described_class.load(hash)
      expect(error.error_type).to be_a(Symbol)
    end
  end

  describe "round-trip serialization" do
    let(:original_error) do
      described_class.new(
        class_name: "ArgumentError",
        message: "Invalid argument",
        backtrace: ["foo.rb:10", "bar.rb:20"],
        request_id: "req_456",
        error_type: :ssl,
        duration: 1.0,
        url: "https://example.com",
        http_method: :get,
        callback_args: {"action" => "fetch", "count" => 5}
      )
    end

    it "preserves all data through as_json and load" do
      hash = original_error.as_json
      restored_error = described_class.load(hash)

      expect(restored_error.error_class).to eq(original_error.error_class)
      expect(restored_error.message).to eq(original_error.message)
      expect(restored_error.backtrace).to eq(original_error.backtrace)
      expect(restored_error.request_id).to eq(original_error.request_id)
      expect(restored_error.error_type).to eq(original_error.error_type)
      expect(restored_error.duration).to eq(original_error.duration)
      expect(restored_error.url).to eq(original_error.url)
      expect(restored_error.http_method).to eq(original_error.http_method)
      expect(restored_error.callback_args.to_h).to eq(original_error.callback_args.to_h)
    end
  end

  describe "#error_class" do
    context "when class exists" do
      it "returns the exception class constant" do
        error = described_class.new(
          class_name: "StandardError",
          message: "Test",
          backtrace: [],
          request_id: "req_123",
          error_type: :unknown,
          duration: 1.0,
          url: "https://example.com",
          http_method: :get
        )

        expect(error.error_class).to eq(StandardError)
      end

      it "works with nested classes" do
        error = described_class.new(
          class_name: "OpenSSL::SSL::SSLError",
          message: "Test",
          backtrace: [],
          request_id: "req_123",
          error_type: :ssl,
          duration: 1.0,
          url: "https://example.com",
          http_method: :get
        )

        expect(error.error_class).to eq(OpenSSL::SSL::SSLError)
      end
    end
  end
end
