# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::ResponseReader do
  let(:config) { PatientHttp::Configuration.new }
  let(:processor) { instance_double(PatientHttp::Processor, config: config, stopping?: false, stopped?: false) }
  let(:response_reader) { described_class.new(processor) }

  # Read the raw chunks and decode them into the final body, the same two
  # steps the processor performs (read on the reactor, decode on a completion
  # worker).
  def read_and_decode(async_response, headers_hash)
    chunks = response_reader.read_raw_body(async_response, headers_hash)
    response_reader.decode_body(chunks, headers_hash)
  end

  describe "#read_raw_body" do
    let(:body_chunks) { ["Hello, ", "World!"] }
    let(:body_double) { Protocol::HTTP::Body::Buffered.new(body_chunks.dup) }
    let(:async_response) { instance_double("Async::HTTP::Protocol::Response", body: body_double) }
    let(:headers_hash) { {} }

    context "when response has no body" do
      let(:async_response) { instance_double("Async::HTTP::Protocol::Response", body: nil) }

      it "returns nil" do
        expect(response_reader.read_raw_body(async_response, headers_hash)).to be_nil
      end
    end

    context "when the response is for a HEAD request" do
      let(:body_double) { Protocol::HTTP::Body::Head.new(50_000_000) }
      let(:headers_hash) { {"content-length" => "50000000"} }

      before do
        config.max_response_size = 1_000_000
      end

      it "does not apply the size limit to the content-length header" do
        expect(response_reader.read_raw_body(async_response, headers_hash)).to eq([])
      end
    end

    context "when response has a body" do
      it "returns the raw chunks" do
        result = response_reader.read_raw_body(async_response, headers_hash)
        expect(result).to eq(["Hello, ", "World!"])
      end
    end

    context "when content-length exceeds max_response_size" do
      let(:headers_hash) { {"content-length" => "10000001"} }

      before do
        config.max_response_size = 10_000_000
      end

      it "raises ResponseTooLargeError" do
        expect {
          response_reader.read_raw_body(async_response, headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /10000001 bytes.*exceeds maximum/)
      end
    end

    context "when content-length is within max_response_size" do
      let(:headers_hash) { {"content-length" => "13"} }

      before do
        config.max_response_size = 10_000_000
      end

      it "reads the body" do
        result = read_and_decode(async_response, headers_hash)
        expect(result).to eq("Hello, World!")
      end
    end

    context "when body exceeds max_response_size during reading" do
      before do
        config.max_response_size = 10
        # A chunked body does not declare its length.
        allow(body_double).to receive(:length).and_return(nil)
      end

      it "raises ResponseTooLargeError" do
        expect {
          response_reader.read_raw_body(async_response, headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /exceeded maximum allowed size/)
      end

      it "closes the body on error" do
        expect(body_double).to receive(:close).with(kind_of(PatientHttp::ResponseTooLargeError))
        expect {
          response_reader.read_raw_body(async_response, headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError)
      end
    end

    context "when body is exactly at max_response_size" do
      before do
        config.max_response_size = 13
      end

      it "reads the body successfully" do
        result = read_and_decode(async_response, headers_hash)
        expect(result).to eq("Hello, World!")
      end
    end

    context "when the body declares its length without a content-length header" do
      before do
        config.max_response_size = 10
      end

      it "applies the size limit before the read starts" do
        expect(body_double).not_to receive(:read)
        expect {
          response_reader.read_raw_body(async_response, headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /\(13 bytes\) exceeds maximum/)
      end

      it "closes the body" do
        expect(body_double).to receive(:close).with(kind_of(PatientHttp::ResponseTooLargeError))
        expect {
          response_reader.read_raw_body(async_response, headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError)
      end
    end

    context "with a max_response_size for the request" do
      it "uses the request limit instead of the configured limit" do
        config.max_response_size = 1_000_000

        expect {
          response_reader.read_raw_body(async_response, headers_hash, max_response_size: 10)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /\(10 bytes\)/)
      end

      it "allows a body larger than the configured limit" do
        config.max_response_size = 10

        result = response_reader.read_raw_body(async_response, headers_hash, max_response_size: 100)
        expect(result).to eq(["Hello, ", "World!"])
      end

      it "applies the request limit while reading a body of unknown length" do
        config.max_response_size = 1_000_000
        allow(body_double).to receive(:length).and_return(nil)

        expect {
          response_reader.read_raw_body(async_response, headers_hash, max_response_size: 10)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /exceeded maximum allowed size \(10 bytes\)/)
      end
    end

    context "with a read timeout" do
      it "reads chunks that arrive within the read timeout" do
        result = Async do
          response_reader.read_raw_body(async_response, headers_hash, read_timeout: 1)
        end.wait

        expect(result).to eq(["Hello, ", "World!"])
      end

      it "raises ReadTimeoutError when the next chunk does not arrive in time" do
        Async do
          body = Protocol::HTTP::Body::Writable.new
          body.write("first")
          response = instance_double("Async::HTTP::Protocol::Response", body: body)

          expect {
            response_reader.read_raw_body(response, headers_hash, read_timeout: 0.05)
          }.to raise_error(PatientHttp::ReadTimeoutError)
        end.wait
      end

      it "starts the timer again for each chunk" do
        Async do |task|
          body = Protocol::HTTP::Body::Writable.new
          writer = task.async do
            4.times do |i|
              sleep(0.04)
              body.write("chunk#{i}")
            end
            body.close_write
          end
          response = instance_double("Async::HTTP::Protocol::Response", body: body)

          result = response_reader.read_raw_body(response, headers_hash, read_timeout: 0.1)

          expect(result).to eq(["chunk0", "chunk1", "chunk2", "chunk3"])
          writer.wait
        end.wait
      end
    end

    context "when processor is stopping" do
      let(:processor) { instance_double(PatientHttp::Processor) }
      let(:config) { PatientHttp::Configuration.new }
      let(:response_reader) { described_class.new(processor) }

      before do
        allow(processor).to receive(:config).and_return(config)
        allow(processor).to receive(:stopped?).and_return(false)
      end

      it "finishes reading the body so in-flight responses can be delivered" do
        result = read_and_decode(async_response, headers_hash)
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
      end

      it "aborts the read" do
        expect do
          response_reader.read_raw_body(async_response, headers_hash)
        end.to raise_error(described_class::ReadAbortedError)
      end

      it "closes the body" do
        expect(body_double).to receive(:close).with(kind_of(described_class::ReadAbortedError))
        expect do
          response_reader.read_raw_body(async_response, headers_hash)
        end.to raise_error(described_class::ReadAbortedError)
      end
    end
  end

  describe "#decode_body" do
    it "returns nil for nil chunks" do
      expect(response_reader.decode_body(nil, {})).to be_nil
    end

    it "joins chunks into a binary string" do
      result = response_reader.decode_body(["Hello, ", "World!"], {})

      expect(result).to eq("Hello, World!")
      expect(result.encoding).to eq(Encoding::ASCII_8BIT)
    end

    context "with a gzip content encoding" do
      it "inflates the body" do
        gzipped = Zlib.gzip("Hello, World!")
        headers_hash = {"content-encoding" => "gzip"}

        result = response_reader.decode_body([gzipped], headers_hash)

        expect(result).to eq("Hello, World!")
      end

      it "inflates a body split across chunks" do
        gzipped = Zlib.gzip("Hello, World!" * 100)
        chunks = [gzipped[0, 20], gzipped[20..]]
        headers_hash = {"content-encoding" => "gzip"}

        result = response_reader.decode_body(chunks, headers_hash)

        expect(result).to eq("Hello, World!" * 100)
      end

      it "is case-insensitive for the encoding name" do
        gzipped = Zlib.gzip("Hello")
        headers_hash = {"content-encoding" => "GZIP"}

        expect(response_reader.decode_body([gzipped], headers_hash)).to eq("Hello")
      end

      it "raises ResponseTooLargeError when the inflated body exceeds max_response_size" do
        config.max_response_size = 1024
        gzipped = Zlib.gzip("a" * 100_000)
        expect(gzipped.bytesize).to be < 1024
        headers_hash = {"content-encoding" => "gzip"}

        expect {
          response_reader.decode_body([gzipped], headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /exceeded maximum allowed size/)
      end

      it "uses the max_response_size for the request instead of the configured limit" do
        config.max_response_size = 1_000_000
        gzipped = Zlib.gzip("a" * 100_000)
        headers_hash = {"content-encoding" => "gzip"}

        expect {
          response_reader.decode_body([gzipped], headers_hash, max_response_size: 1024)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /\(1024 bytes\)/)
      end

      it "inflates past the configured limit when the request limit allows it" do
        config.max_response_size = 1024
        gzipped = Zlib.gzip("a" * 100_000)
        headers_hash = {"content-encoding" => "gzip"}

        body = response_reader.decode_body([gzipped], headers_hash, max_response_size: 200_000)
        expect(body.bytesize).to eq(100_000)
      end

      it "checks the size as the body inflates rather than after it" do
        # A single compressed chunk can expand without bound, so the limit has
        # to be applied to each piece of inflate output.
        gzipped = Zlib.gzip("a" * 500_000)
        headers_hash = {"content-encoding" => "gzip"}
        expect(response_reader).to receive(:validate_inflated_size).at_least(10).times.and_call_original

        expect(response_reader.decode_body([gzipped], headers_hash).bytesize).to eq(500_000)
      end

      it "applies the charset after inflating" do
        gzipped = Zlib.gzip("Hello")
        headers_hash = {"content-encoding" => "gzip", "content-type" => "text/plain; charset=utf-8"}

        result = response_reader.decode_body([gzipped], headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::UTF_8)
      end
    end

    context "with a deflate content encoding" do
      let(:headers_hash) { {"content-encoding" => "deflate"} }

      it "inflates a zlib-wrapped deflate body" do
        deflated = Zlib::Deflate.deflate("Hello, World!")
        expect(deflated[0, 1].unpack1("C") & 0x0f).to eq(8)

        expect(response_reader.decode_body([deflated], headers_hash)).to eq("Hello, World!")
      end

      it "inflates a raw deflate body" do
        deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
        deflated = deflater.deflate("Hello, World!", Zlib::FINISH)
        deflater.close

        expect(response_reader.decode_body([deflated], headers_hash)).to eq("Hello, World!")
      end

      it "inflates a zlib-wrapped body split across chunks" do
        deflated = Zlib::Deflate.deflate("Hello, World!" * 100)
        chunks = [deflated[0, 20], deflated[20..]]

        expect(response_reader.decode_body(chunks, headers_hash)).to eq("Hello, World!" * 100)
      end

      it "raises when the body is not deflated in any supported format" do
        expect {
          response_reader.decode_body(["not compressed at all"], headers_hash)
        }.to raise_error(Zlib::Error)
      end

      it "enforces max_response_size on a zlib-wrapped body" do
        config.max_response_size = 1024
        deflated = Zlib::Deflate.deflate("a" * 100_000)
        expect(deflated.bytesize).to be < 1024

        expect {
          response_reader.decode_body([deflated], headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /exceeded maximum allowed size/)
      end

      it "enforces max_response_size on a raw body reached by the fallback" do
        config.max_response_size = 1024
        deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
        deflated = deflater.deflate("a" * 100_000, Zlib::FINISH)
        deflater.close
        expect(deflated.bytesize).to be < 1024

        expect {
          response_reader.decode_body([deflated], headers_hash)
        }.to raise_error(PatientHttp::ResponseTooLargeError, /exceeded maximum allowed size/)
      end
    end

    context "with an unknown content encoding" do
      it "returns the joined chunks unchanged" do
        headers_hash = {"content-encoding" => "br"}

        result = response_reader.decode_body(["raw-bytes"], headers_hash)

        expect(result).to eq("raw-bytes")
      end

      it "keeps the body binary instead of applying the charset" do
        headers_hash = {"content-encoding" => "br", "content-type" => "text/html; charset=utf-8"}

        result = response_reader.decode_body([Zlib.gzip("Hello")], headers_hash)

        expect(result.encoding).to eq(Encoding::ASCII_8BIT)
        expect(result).to be_valid_encoding
      end

      it "warns that the body is still encoded" do
        logger = instance_double(Logger)
        allow(config).to receive(:logger).and_return(logger)
        expect(logger).to receive(:warn).with(/content-encoding 'br'; returning the encoded body/)

        response_reader.decode_body(["raw-bytes"], {"content-encoding" => "br"})
      end

      it "does not warn when every encoding was decoded" do
        logger = instance_double(Logger)
        allow(config).to receive(:logger).and_return(logger)
        expect(logger).not_to receive(:warn)

        response_reader.decode_body([Zlib.gzip("Hello")], {"content-encoding" => "gzip"})
      end
    end

    context "with a list of content encodings" do
      it "inflates a gzip body listed with identity" do
        gzipped = Zlib.gzip("Hello, World!")
        headers_hash = {"content-encoding" => "gzip,identity"}

        expect(response_reader.decode_body([gzipped], headers_hash)).to eq("Hello, World!")
      end

      it "ignores whitespace and casing between the names" do
        gzipped = Zlib.gzip("Hello, World!")
        headers_hash = {"content-encoding" => "GZIP , Identity"}

        expect(response_reader.decode_body([gzipped], headers_hash)).to eq("Hello, World!")
      end

      it "decodes stacked encodings from the outermost inward" do
        deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
        inner = deflater.deflate("Hello, World!", Zlib::FINISH)
        deflater.close
        headers_hash = {"content-encoding" => "deflate, gzip"}

        expect(response_reader.decode_body([Zlib.gzip(inner)], headers_hash)).to eq("Hello, World!")
      end

      it "stops at the first encoding it cannot decode" do
        headers_hash = {"content-encoding" => "br, gzip"}

        result = response_reader.decode_body([Zlib.gzip("raw-bytes")], headers_hash)

        expect(result).to eq("raw-bytes")
      end

      it "leaves the body encoded when the outermost encoding is unknown" do
        gzipped = Zlib.gzip("Hello")
        headers_hash = {"content-encoding" => "gzip, br"}

        expect(response_reader.decode_body([gzipped], headers_hash)).to eq(gzipped)
      end

      it "treats an identity-only body as already decoded" do
        headers_hash = {"content-encoding" => "identity"}

        expect(response_reader.decode_body(["Hello"], headers_hash)).to eq("Hello")
      end
    end

    context "with charset in Content-Type header" do
      let(:chunks) { ["Hello"] }

      it "applies UTF-8 encoding when charset=utf-8 is specified" do
        headers_hash = {"content-type" => "text/html; charset=utf-8"}
        result = response_reader.decode_body(chunks, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::UTF_8)
      end

      it "applies ISO-8859-1 encoding when charset=ISO-8859-1 is specified" do
        headers_hash = {"content-type" => "text/plain; charset=ISO-8859-1"}
        result = response_reader.decode_body(chunks, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::ISO_8859_1)
      end

      it "handles charset with different spacing" do
        headers_hash = {"content-type" => "application/json;charset=utf-8"}
        result = response_reader.decode_body(chunks, headers_hash)

        expect(result.encoding).to eq(Encoding::UTF_8)
      end

      it "handles charset with quoted values" do
        headers_hash = {"content-type" => "text/html; charset=\"utf-8\""}
        result = response_reader.decode_body(chunks, headers_hash)

        # The regex may capture the quotes; this spec verifies that a quoted
        # charset value does not cause an error and the body is still returned.
        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::UTF_8)
      end

      it "keeps original encoding when no charset is specified" do
        headers_hash = {"content-type" => "text/plain"}
        result = response_reader.decode_body(chunks, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::ASCII_8BIT)
      end

      it "keeps original encoding when Content-Type header is missing" do
        headers_hash = {}
        result = response_reader.decode_body(chunks, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::ASCII_8BIT)
      end

      it "handles invalid charset gracefully" do
        headers_hash = {"content-type" => "text/plain; charset=INVALID-CHARSET"}
        logger = instance_double(Logger)
        allow(config).to receive(:logger).and_return(logger)
        expect(logger).to receive(:warn).with(/Unknown charset 'INVALID-CHARSET'/)

        result = response_reader.decode_body(chunks, headers_hash)

        expect(result).to eq("Hello")
        expect(result.encoding).to eq(Encoding::ASCII_8BIT)
      end

      it "is case-insensitive for charset parameter" do
        headers_hash = {"content-type" => "text/html; CHARSET=UTF-8"}
        result = response_reader.decode_body(chunks, headers_hash)

        expect(result.encoding).to eq(Encoding::UTF_8)
      end
    end
  end

  describe ".with_read_timeout" do
    it "returns the value of the block" do
      result = Async { described_class.with_read_timeout(1) { :done } }.wait
      expect(result).to eq(:done)
    end

    it "runs the block without a timer when the read timeout is nil" do
      expect(described_class.with_read_timeout(nil) { :done }).to eq(:done)
    end

    it "raises ReadTimeoutError when the block takes too long" do
      expect {
        Async { described_class.with_read_timeout(0.01) { sleep(1) } }.wait
      }.to raise_error(PatientHttp::ReadTimeoutError, /No data received/)
    end

    it "raises an error that is an Async::TimeoutError" do
      expect(PatientHttp::ReadTimeoutError.ancestors).to include(Async::TimeoutError)
    end

    it "does not fire after the block finishes" do
      result = Async do
        described_class.with_read_timeout(0.02) { :done }
        sleep(0.05)
        :still_running
      end.wait

      expect(result).to eq(:still_running)
    end
  end

  describe ".split_encodings" do
    it "returns nothing for a response with no content-encoding" do
      expect(described_class.split_encodings({})).to eq([[], []])
    end

    it "reports a supported encoding as decodable" do
      expect(described_class.split_encodings({"content-encoding" => "gzip"})).to eq([[], ["gzip"]])
    end

    it "reports an unsupported encoding as remaining" do
      expect(described_class.split_encodings({"content-encoding" => "br"})).to eq([["br"], []])
    end

    it "splits a list at the outermost unsupported encoding" do
      headers_hash = {"content-encoding" => "br, gzip, identity"}

      expect(described_class.split_encodings(headers_hash)).to eq([["br"], ["gzip", "identity"]])
    end

    it "keeps everything applied before an unsupported encoding" do
      headers_hash = {"content-encoding" => "gzip, br"}

      expect(described_class.split_encodings(headers_hash)).to eq([["gzip", "br"], []])
    end

    it "ignores empty entries in the list" do
      expect(described_class.split_encodings({"content-encoding" => "gzip,,"})).to eq([[], ["gzip"]])
    end
  end
end
