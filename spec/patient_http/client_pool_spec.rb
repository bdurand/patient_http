# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::ClientPool do
  let(:pool) { described_class.new(max_size: 3, retries: 3) }

  after do
    pool.close
  end

  describe "#initialize" do
    it "sets max_size" do
      expect(pool.max_size).to eq(3)
    end

    it "sets retries" do
      expect(pool.retries).to eq(3)
    end

    it "sets connection_timeout when provided" do
      pool_with_timeout = described_class.new(max_size: 3, connection_timeout: 10)
      expect(pool_with_timeout.connection_timeout).to eq(10)
      pool_with_timeout.close
    end

    it "sets proxy_url when provided" do
      pool_with_proxy = described_class.new(max_size: 3, proxy_url: "http://proxy.example.com:8080")
      expect(pool_with_proxy.proxy_url).to eq("http://proxy.example.com:8080")
      pool_with_proxy.close
    end

    it "sets protocol when provided" do
      pool_with_protocol = described_class.new(max_size: 3, protocol: :http1)
      expect(pool_with_protocol.protocol).to eq(:http1)
      pool_with_protocol.close
    end

    it "raises ArgumentError for an unsupported protocol" do
      expect {
        described_class.new(max_size: 3, protocol: :spdy)
      }.to raise_error(ArgumentError, /protocol must be one of/)
    end
  end

  describe "protocol enforcement" do
    it "forces HTTP/1.1 on client endpoints when protocol is :http1" do
      pool_with_protocol = described_class.new(max_size: 3, protocol: :http1)
      client = pool_with_protocol.client_for(Async::HTTP::Endpoint.parse("https://example.com"))
      endpoint = client.delegate.endpoint

      expect(endpoint.protocol).to eq(Async::HTTP::Protocol::HTTP11)
      expect(endpoint.alpn_protocols).to eq(["http/1.1"])
      pool_with_protocol.close
    end

    it "forces HTTP/2 on client endpoints when protocol is :http2" do
      pool_with_protocol = described_class.new(max_size: 3, protocol: :http2)
      client = pool_with_protocol.client_for(Async::HTTP::Endpoint.parse("https://example.com"))
      endpoint = client.delegate.endpoint

      expect(endpoint.protocol).to eq(Async::HTTP::Protocol::HTTP2)
      expect(endpoint.alpn_protocols).to eq(["h2"])
      pool_with_protocol.close
    end

    it "leaves endpoints unchanged when no protocol is set" do
      original_endpoint = Async::HTTP::Endpoint.parse("https://example.com")
      client = pool.client_for(original_endpoint)

      expect(client.delegate.endpoint).to be(original_endpoint)
    end
  end

  describe "#size" do
    it "returns 0 for empty pool" do
      expect(pool.size).to eq(0)
    end
  end

  describe "#close" do
    it "handles multiple close calls gracefully" do
      pool.close
      expect { pool.close }.not_to raise_error
    end
  end
end
