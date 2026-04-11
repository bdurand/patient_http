# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Payload do
  describe ".encode" do
    context "with text mimetype" do
      it "returns :text encoding for small text" do
        value = (+"small text").force_encoding(Encoding::ASCII_8BIT)
        encoding, encoded, charset = described_class.encode(value, "text/plain")
        expect(encoding).to eq(:text)
        expect(encoded).to eq(value)
        expect(encoded.encoding).to eq(Encoding::UTF_8)
        expect(charset).to eq(Encoding::UTF_8.name)
      end

      it "returns :text encoding for small text" do
        value = (+"small text").force_encoding(Encoding::ASCII_8BIT)
        encoding, encoded, charset = described_class.encode(value, "text/plain; charset=UTF-8")
        expect(encoding).to eq(:text)
        expect(encoded).to eq(value)
        expect(encoded.encoding).to eq(Encoding::UTF_8)
        expect(charset).to eq(Encoding::UTF_8.name)
      end

      it "returns encodes text with no charset to UTF-8 if possible" do
        value = (+"small text").force_encoding(Encoding::ASCII_8BIT)
        encoding, encoded, charset = described_class.encode(value, "text/plain")
        expect(encoding).to eq(:text)
        expect(encoded).to eq(value)
        expect(encoded.encoding).to eq(Encoding::UTF_8)
        expect(charset).to eq(Encoding::UTF_8.name)
      end

      it "return ascii-8bit text if there is no charset and high order bits" do
        value = String.new("café", encoding: Encoding::ASCII_8BIT)
        encoding, encoded, charset = described_class.encode(value, "text/plain")
        expect(encoding).to eq(:text)
        expect(encoded).to eq(value)
        expect(encoded.encoding).to eq(Encoding::ASCII_8BIT)
        expect(charset).to eq(Encoding::ASCII_8BIT.name)
      end

      it "converts non-UTF8 text to UTF-8" do
        value = (+"caf\xE9").force_encoding(Encoding::ASCII_8BIT)  # "café" in ISO-8859-1
        encoding, encoded, charset = described_class.encode(value, "application/json; charset=ISO-8859-1")
        expect(encoding).to eq(:text)
        expect(encoded).to eq("café")
        expect(encoded.encoding).to eq(Encoding::UTF_8)
        expect(charset).to eq(Encoding::UTF_8.name)
      end

      it "returns :gzipped encoding for large compressible text" do
        value = "repeat " * 1000  # compressible
        encoding, encoded, charset = described_class.encode(value, "text/plain")
        expect(encoding).to eq(:gzipped)
        expect(encoded).to be_a(String)
        expect(encoded).not_to eq(value)
        expect(encoded.encoding).to eq(Encoding::US_ASCII)
        expect(charset).to eq(Encoding::UTF_8.name)
      end

      it "produces valid gzip output for large compressible text" do
        value = "repeat " * 1000
        _encoding, encoded, _charset = described_class.encode(value, "text/plain")
        compressed = encoded.unpack1("m0")
        expect(Zlib.gunzip(compressed)).to eq(value)
      end
    end

    context "with binary mimetype" do
      let(:mimetype) { "application/octet-stream" }

      it "returns :binary encoding" do
        value = "binary data"
        encoding, encoded, charset = described_class.encode(value, mimetype)
        expect(encoding).to eq(:binary)
        expect(encoded).to eq([value].pack("m0"))
        expect(encoded.encoding).to eq(Encoding::US_ASCII)
        expect(charset).to eq(Encoding::BINARY.name)
      end
    end

    context "with json mimetype" do
      let(:mimetype) { "application/json" }

      it "treats as text" do
        value = (+'{"key": "value"}').force_encoding(Encoding::ASCII_8BIT)
        encoding, value, charset = described_class.encode(value, mimetype)
        expect(encoding).to eq(:text)
        expect(value).to eq('{"key": "value"}')
        expect(charset).to eq(Encoding::UTF_8.name)
      end
    end
  end

  describe ".decode" do
    it "decodes :text" do
      value = "plain text"
      decoded = described_class.decode(value, :text, Encoding::UTF_8.name)
      expect(decoded).to eq(value)
      expect(decoded.encoding).to eq(Encoding::UTF_8)
    end

    it "decodes text to the right charset" do
      value = (+"cafe").force_encoding(Encoding::ASCII_8BIT)
      decoded = described_class.decode(value, :text, Encoding::ISO_8859_1.name)
      expect(decoded).to eq("cafe")
      expect(decoded.encoding).to eq(Encoding::ISO_8859_1)
    end

    it "decodes :binary" do
      value = "binary data"
      encoded = [value].pack("m0")
      decoded = described_class.decode(encoded, :binary, Encoding::BINARY.name)
      expect(decoded).to eq(value)
      expect(decoded.encoding).to eq(Encoding::BINARY)
    end

    it "decodes :gzipped" do
      value = "compressible text " * 100
      gzipped = Zlib.gzip(value)
      encoded = [gzipped].pack("m0")
      decoded = described_class.decode(encoded, :gzipped, Encoding::UTF_8.name)
      expect(decoded).to eq(value)
      expect(decoded.encoding).to eq(Encoding::UTF_8)
    end
  end

  describe "#value" do
    it "decodes the encoded value" do
      encoded = ["test"].pack("m0")
      payload = described_class.new(:binary, encoded, Encoding::BINARY.name)
      expect(payload.value).to eq("test")
      expect(payload.value.encoding).to eq(Encoding::BINARY)
    end
  end

  describe "#as_json" do
    it "returns hash with string keys" do
      payload = described_class.new(:text, "data", Encoding::UTF_8.name)
      hash = payload.as_json
      expect(hash).to eq({
        "encoding" => "text",
        "value" => "data",
        "charset" => Encoding::UTF_8.name
      })
    end
  end

  describe ".load" do
    it "creates payload from hash" do
      hash = {
        "mimetype" => "text/plain",
        "encoding" => "text",
        "value" => "data",
        "charset" => Encoding::UTF_8.name
      }
      payload = described_class.load(hash)
      expect(payload.encoding).to eq(:text)
      expect(payload.encoded_value).to eq("data")
      expect(payload.value).to eq("data")
      expect(payload.charset).to eq(Encoding::UTF_8.name)
    end
  end

  describe "round trip" do
    it "encodes and decodes correctly" do
      original_value = (+"test data").force_encoding(Encoding::ASCII_8BIT)
      mimetype = "text/plain; charset=utf-8"
      encoding, encoded_value, charset = described_class.encode(original_value, mimetype)
      payload = described_class.new(encoding, encoded_value, charset)
      expect(payload.value).to eq(original_value)
      hash = payload.as_json
      restored = described_class.load(hash)
      expect(restored.value).to eq(original_value)
      expect(restored.value.encoding).to eq(Encoding::UTF_8)
    end

    it "encodes and decodes nil value" do
      original_value = nil
      mimetype = "text/plain"
      encoding, encoded_value = described_class.encode(original_value, mimetype)
      expect(encoding).to be_nil
      expect(encoded_value).to be_nil
      payload = described_class.new(encoding, encoded_value, Encoding::UTF_8)
      expect(payload.value).to be_nil
      hash = payload.as_json
      restored = described_class.load(hash)
      expect(restored).to be_nil
      expect(described_class.load(nil)).to be_nil
    end
  end
end
