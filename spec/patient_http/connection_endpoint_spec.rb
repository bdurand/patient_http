# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::ConnectionEndpoint do
  let(:server) { TCPServer.new("127.0.0.1", 0) }
  let(:port) { server.addr[1] }
  let(:endpoint) { Async::HTTP::Endpoint.parse("http://127.0.0.1:#{port}", timeout: 5) }
  let(:wrapped) { described_class.new(endpoint) }

  after do
    server.close
  end

  it "delegates the endpoint attributes the HTTP client reads" do
    expect(wrapped.protocol).to eq(endpoint.protocol)
    expect(wrapped.scheme).to eq("http")
    expect(wrapped.authority).to eq("127.0.0.1:#{port}")
    expect(wrapped.secure?).to be(false)
    expect(wrapped.__getobj__).to be(endpoint)
  end

  describe "#connect" do
    it "returns a connected socket without the per-operation IO timeout" do
      socket = Async { wrapped.connect }.wait

      begin
        expect(socket.timeout).to be_nil
        expect(socket).not_to be_closed
      ensure
        socket.close
      end
    end

    it "yields the socket without the timeout and closes it after the block" do
      yielded = nil

      Async do
        wrapped.connect do |socket|
          yielded = socket
          expect(socket.timeout).to be_nil
        end
      end.wait

      expect(yielded).to be_closed
    end

    it "leaves the timeout in place on the endpoint it wraps" do
      socket = Async { endpoint.connect }.wait

      begin
        expect(socket.timeout).to eq(5)
      ensure
        socket.close
      end
    end

    context "with a connection timeout and a peer that never answers the handshake" do
      # 192.0.2.0/24 is reserved for documentation and is never routed.
      let(:endpoint) { Async::HTTP::Endpoint.parse("http://192.0.2.1:81", timeout: 0.2) }
      let(:wrapped) { described_class.new(endpoint, connection_timeout: 0.2) }

      it "raises IO::TimeoutError once the connection timeout elapses" do
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        expect do
          Async { wrapped.connect }.wait
        end.to raise_error(IO::TimeoutError)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at).to be < 2
      end
    end

    context "with a TCP user timeout" do
      let(:wrapped) { described_class.new(endpoint, tcp_user_timeout: 30) }

      it "limits how long transmitted data may stay unacknowledged where the platform supports it" do
        socket = Async { wrapped.connect }.wait

        begin
          expect(socket).not_to be_closed
          if defined?(Socket::TCP_USER_TIMEOUT)
            expect(socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_USER_TIMEOUT).int).to eq(30_000)
          end
        ensure
          socket.close
        end
      end
    end

    context "without TCP keepalive settings" do
      it "leaves keepalive off" do
        socket = Async { wrapped.connect }.wait

        begin
          expect(socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE).bool).to be(false)
        ensure
          socket.close
        end
      end
    end

    context "with TCP keepalive settings" do
      let(:wrapped) do
        described_class.new(endpoint, tcp_keepalive: {idle: 45, interval: 7, count: 4})
      end

      it "enables keepalive on the socket with the given probe settings" do
        socket = Async { wrapped.connect }.wait

        begin
          expect(socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_KEEPALIVE).bool).to be(true)

          idle_option = defined?(Socket::TCP_KEEPIDLE) ? Socket::TCP_KEEPIDLE : Socket::TCP_KEEPALIVE
          expect(socket.getsockopt(Socket::IPPROTO_TCP, idle_option).int).to eq(45)
          expect(socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPINTVL).int).to eq(7)
          expect(socket.getsockopt(Socket::IPPROTO_TCP, Socket::TCP_KEEPCNT).int).to eq(4)
        ensure
          socket.close
        end
      end
    end
  end
end
