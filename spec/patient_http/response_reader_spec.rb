# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::ResponseReader do
  let(:config) { PatientHttp::Configuration.new }
  let(:processor) { instance_double(PatientHttp::Processor, config: config, stopping?: false, stopped?: false) }
  let(:response_reader) { described_class.new(processor) }

  describe "#read_body" do
    let(:body_double) { instance_double(Protocol::HTTP::Body::Buffered) }
    let(:async_response) { instance_double("Async::HTTP::Protocol::Response", body: body_double) }
    let(:headers_hash) { {} }

    context "when response has no body" do
      let(:async_response) { instance_double("Async::HTTP::Protocol::Response", body: nil) }

      it "returns nil" do
        expect(response_reader.read_body(async_response, headers_hash)).to be_nil
      end
    end

    context "when response has a body" do
      before do
        allow(body_double).to receive(:each).and_yield("Hello, ").and_yield("World!")
      end

      it "reads and joins all chunks" do
        result = response_reader.read_body(async_response, headers_hash)
        expect(result).to eq("Hello, World!")
      end
    end

    context "when content-length exceeds max_response_size" do
      let(:headers_hash) { {"content-length" => "10000001"} }

      before do
        config.max_response_size = 10_000_000
      end

      it "raises ResponseTooLargeError" do
        expect {
          response_reader.read_body(async_response, headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /10000001 bytes.*exceeds maximum/)
      end
    end

    context "when content-length is within max_response_size" do
      let(:headers_hash) { {"content-length" => "13"} }

      before do
        config.max_response_size = 10_000_000
        allow(body_double).to receive(:each).and_yield("Hello, World!")
      end

      it "reads the body" do
        result = response_reader.read_body(async_response, headers_hash)
        expect(result).to eq("Hello, World!")
      end
    end

    context "when body exceeds max_response_size during reading" do
      before do
        config.max_response_size = 10
        allow(body_double).to receive(:each).and_yield("Hello, ").and_yield("World!")
        allow(body_double).to receive(:close)
      end

      it "raises ResponseTooLargeError" do
        expect {
          response_reader.read_body(async_response, headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /exceeded maximum allowed size/)
      end

      it "closes the body on error" do
        expect(body_double).to receive(:close)
        expect {
          response_reader.read_body(async_response, headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError)
      end
    end

    context "when body is exactly at max_response_size" do
      before do
        config.max_response_size = 13
        allow(body_double).to receive(:each).and_yield("Hello, World!")
      end

      it "reads the body successfully" do
        result = response_reader.read_body(async_response, headers_hash)
        expect(result).to eq("Hello, World!")
      end
    end

    context "with charset in Content-Type header" do
      before do
        allow(body_double).to receive(:each).and_yield("Hello")
      end

      it "applies UTF-8 encoding when charset=utf-8 is specified" do
        headers_hash = {"content-type" => "text/html; charset=utf-8"}
        result = response_reader.read_body(async_response, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::UTF_8)
      end

      it "applies ISO-8859-1 encoding when charset=ISO-8859-1 is specified" do
        headers_hash = {"content-type" => "text/plain; charset=ISO-8859-1"}
        result = response_reader.read_body(async_response, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::ISO_8859_1)
      end

      it "handles charset with different spacing" do
        headers_hash = {"content-type" => "application/json;charset=utf-8"}
        result = response_reader.read_body(async_response, headers_hash)

        expect(result.encoding).to eq(Encoding::UTF_8)
      end

      it "handles charset with quoted values" do
        headers_hash = {"content-type" => "text/html; charset=\"utf-8\""}
        result = response_reader.read_body(async_response, headers_hash)

        # The regex may capture the quotes; this spec verifies that a quoted
        # charset value does not cause an error and the body is still returned.
        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::UTF_8)
      end

      it "keeps original encoding when no charset is specified" do
        headers_hash = {"content-type" => "text/plain"}
        result = response_reader.read_body(async_response, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::ASCII_8BIT)
      end

      it "keeps original encoding when Content-Type header is missing" do
        headers_hash = {}
        result = response_reader.read_body(async_response, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::ASCII_8BIT)
      end

      it "handles invalid charset gracefully" do
        headers_hash = {"content-type" => "text/plain; charset=INVALID-CHARSET"}
        logger = instance_double(Logger)
        allow(config).to receive(:logger).and_return(logger)
        expect(logger).to receive(:warn).with(/Unknown charset 'INVALID-CHARSET'/)

        result = response_reader.read_body(async_response, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::ASCII_8BIT)
      end

      it "is case-insensitive for charset parameter" do
        headers_hash = {"content-type" => "text/html; CHARSET=UTF-8"}
        result = response_reader.read_body(async_response, headers_hash)

        expect(result.encoding).to eq(Encoding::UTF_8)
      end
    end

    context "when processor is stopping" do
      let(:processor) { instance_double(PatientHttp::Processor) }
      let(:config) { PatientHttp::Configuration.new }
      let(:response_reader) { described_class.new(processor) }

      before do
        allow(processor).to receive(:config).and_return(config)
        allow(processor).to receive(:stopped?).and_return(false)
        allow(body_double).to receive(:each).and_yield("Hello, ").and_yield("World!")
        allow(body_double).to receive(:close)
      end

      it "finishes reading the body so in-flight responses can be delivered" do
        result = response_reader.read_body(async_response, headers_hash)
        expect(result).to eq("Hello, World!")
      end
    end

    context "when processor is stopped" do
      let(:processor) { instance_double(PatientHttp::Processor) }
      let(:config) { PatientHttp::Configuration.new }
      let(:response_reader) { described_class.new(processor) }

      before do
        allow(processor).to receive(:config).and_return(config)
        allow(processor).to receive(:stopped?).and_return(true)
        allow(body_double).to receive(:each).and_yield("Hello, ").and_yield("World!")
        allow(body_double).to receive(:close)
      end

      it "aborts the read" do
        expect do
          response_reader.read_body(async_response, headers_hash)
        end.to raise_error(described_class::ReadAbortedError)
      end

      it "closes the body" do
        expect(body_double).to receive(:close)
        expect do
          response_reader.read_body(async_response, headers_hash)
        end.to raise_error(described_class::ReadAbortedError)
      end
    end
  end
end
