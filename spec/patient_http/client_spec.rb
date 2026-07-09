# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Client do
  let(:config) do
    PatientHttp::Configuration.new(
      request_timeout: 30,
      user_agent: "TestAgent/1.0"
    )
  end

  let(:processor) do
    instance_double(
      PatientHttp::Processor,
      config: config,
      stopped?: false,
      stopping?: false
    )
  end

  let(:client) { described_class.new(processor) }
  let(:request_id) { "test-request-123" }

  describe "#initialize" do
    it "passes the configured protocol to the client pool" do
      config.protocol = :http1

      expect(PatientHttp::ClientPool).to receive(:new)
        .with(hash_including(protocol: :http1))
        .and_call_original

      described_class.new(processor)
    end
  end

  describe "#make_request" do
    let(:request) do
      PatientHttp::Request.new(
        :get,
        "https://api.example.com/users",
        headers: {"Authorization" => "Bearer token123"}
      )
    end

    context "with a successful GET request" do
      it "returns response data with status, headers, and body" do
        stub_request(:get, "https://api.example.com/users")
          .with(headers: {
            "Authorization" => "Bearer token123",
            "User-Agent" => "TestAgent/1.0",
            "X-Request-Id" => request_id
          })
          .to_return(
            status: 200,
            body: '{"users": [{"id": 1, "name": "Alice"}]}',
            headers: {"Content-Type" => "application/json"}
          )

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(200)
        expect(result[:body]).to eq('{"users": [{"id": 1, "name": "Alice"}]}')
        expect(result[:headers]["content-type"]).to eq("application/json")
      end
    end

    context "with a POST request with body" do
      let(:request) do
        PatientHttp::Request.new(
          :post,
          "https://api.example.com/users",
          headers: {"Content-Type" => "application/json"},
          body: '{"name": "Bob", "email": "bob@example.com"}'
        )
      end

      it "sends the request body and returns response" do
        stub_request(:post, "https://api.example.com/users")
          .with(
            body: '{"name": "Bob", "email": "bob@example.com"}',
            headers: {
              "Content-Type" => "application/json",
              "User-Agent" => "TestAgent/1.0",
              "X-Request-Id" => request_id
            }
          )
          .to_return(
            status: 201,
            body: '{"id": 42, "name": "Bob"}',
            headers: {"Content-Type" => "application/json"}
          )

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(201)
        expect(result[:body]).to eq('{"id": 42, "name": "Bob"}')
      end
    end

    context "with a PUT request" do
      let(:request) do
        PatientHttp::Request.new(
          :put,
          "https://api.example.com/users/42",
          headers: {"Content-Type" => "application/json"},
          body: '{"name": "Bob Updated"}'
        )
      end

      it "sends PUT request and returns response" do
        stub_request(:put, "https://api.example.com/users/42")
          .with(
            body: '{"name": "Bob Updated"}',
            headers: {
              "Content-Type" => "application/json",
              "User-Agent" => "TestAgent/1.0",
              "X-Request-Id" => request_id
            }
          )
          .to_return(
            status: 200,
            body: '{"id": 42, "name": "Bob Updated"}',
            headers: {"Content-Type" => "application/json"}
          )

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(200)
        expect(result[:body]).to eq('{"id": 42, "name": "Bob Updated"}')
      end
    end

    context "with a DELETE request" do
      let(:request) do
        PatientHttp::Request.new(
          :delete,
          "https://api.example.com/users/42"
        )
      end

      it "sends DELETE request and returns response" do
        stub_request(:delete, "https://api.example.com/users/42")
          .with(headers: {
            "User-Agent" => "TestAgent/1.0",
            "X-Request-Id" => request_id
          })
          .to_return(status: 204, body: "")

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(204)
        expect(result[:body]).to be_nil
      end
    end

    context "when config has no user_agent set" do
      let(:config) do
        PatientHttp::Configuration.new(user_agent: nil)
      end

      it "does not include User-Agent header" do
        stub_request(:get, "https://api.example.com/users")
          .with(headers: {
            "Authorization" => "Bearer token123",
            "X-Request-Id" => request_id
          })
          .to_return(status: 200, body: "OK")

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(200)
      end
    end

    context "when request has custom timeout" do
      let(:request) do
        PatientHttp::Request.new(
          :get,
          "https://api.example.com/slow",
          timeout: 5
        )
      end

      it "uses the request timeout instead of config timeout" do
        stub_request(:get, "https://api.example.com/slow")
          .to_return(status: 200, body: "Slow response")

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(200)
        expect(result[:body]).to eq("Slow response")
      end
    end

    context "when request times out" do
      let(:request) do
        PatientHttp::Request.new(
          :get,
          "https://api.example.com/timeout",
          timeout: 0.1
        )
      end

      it "raises Async::TimeoutError" do
        stub_request(:get, "https://api.example.com/timeout")
          .to_timeout

        expect {
          Async do
            client.make_request(request, request_id)
          end.wait
        }.to raise_error(Async::TimeoutError)
      end
    end

    context "with 4xx response" do
      it "returns the error response" do
        stub_request(:get, "https://api.example.com/users")
          .to_return(
            status: 404,
            body: '{"error": "Not found"}',
            headers: {"Content-Type" => "application/json"}
          )

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(404)
        expect(result[:body]).to eq('{"error": "Not found"}')
      end
    end

    context "with 5xx response" do
      it "returns the error response" do
        stub_request(:get, "https://api.example.com/users")
          .to_return(
            status: 500,
            body: "Internal Server Error",
            headers: {"Content-Type" => "text/plain"}
          )

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(500)
        expect(result[:body]).to eq("Internal Server Error")
      end
    end

    context "with empty response body" do
      it "returns nil body" do
        stub_request(:get, "https://api.example.com/users")
          .to_return(status: 204, body: "")

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(204)
        expect(result[:body]).to be_nil
      end
    end

    context "with custom headers" do
      let(:request) do
        PatientHttp::Request.new(
          :get,
          "https://api.example.com/users",
          headers: {
            "Authorization" => "Bearer token123",
            "X-Custom-Header" => "custom-value",
            "Accept" => "application/json"
          }
        )
      end

      it "includes all request headers plus x-request-id and user-agent" do
        stub_request(:get, "https://api.example.com/users")
          .with(headers: {
            "Authorization" => "Bearer token123",
            "X-Custom-Header" => "custom-value",
            "Accept" => "application/json",
            "User-Agent" => "TestAgent/1.0",
            "X-Request-Id" => request_id
          })
          .to_return(status: 200, body: "OK")

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(200)
      end
    end

    context "with request that overrides user-agent" do
      let(:request) do
        PatientHttp::Request.new(
          :get,
          "https://api.example.com/users",
          headers: {"user-agent" => "CustomAgent/2.0"}
        )
      end

      it "uses the request's user-agent instead of config user-agent" do
        stub_request(:get, "https://api.example.com/users")
          .with(headers: {
            "User-Agent" => "CustomAgent/2.0",
            "X-Request-Id" => request_id
          })
          .to_return(status: 200, body: "OK")

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(200)
      end
    end

    context "with preprocessors" do
      let(:request) do
        PatientHttp::Request.new(
          :get,
          "https://api.example.com/users",
          headers: {"Authorization" => "Bearer token123"},
          preprocessors: :signer
        )
      end

      before do
        config.register_preprocessor(:signer) do |outgoing|
          outgoing.headers["x-signature"] = "#{outgoing.http_method}:#{outgoing.url}:#{outgoing.headers["x-request-id"]}"
          outgoing.headers["x-signed-date"] = "2026-07-02"
          outgoing.add_param("signed", "true")
        end
      end

      it "applies the preprocessor's header and query param changes to the outgoing request" do
        stub_request(:get, "https://api.example.com/users?signed=true")
          .with(headers: {
            "Authorization" => "Bearer token123",
            "User-Agent" => "TestAgent/1.0",
            "X-Request-Id" => request_id,
            "X-Signature" => "get:https://api.example.com/users:#{request_id}",
            "X-Signed-Date" => "2026-07-02"
          })
          .to_return(status: 200, body: "OK")

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:status]).to eq(200)
      end
    end

    context "when network error occurs" do
      it "raises the error" do
        stub_request(:get, "https://api.example.com/users")
          .to_raise(SocketError.new("Failed to connect"))

        expect {
          Async do
            client.make_request(request, request_id)
          end.wait
        }.to raise_error(SocketError, "Failed to connect")
      end

      it "evicts the pooled client when the connection is aborted" do
        stub_request(:get, "https://api.example.com/users")
          .to_raise(Errno::ECONNABORTED)

        client_pool = client.instance_variable_get(:@client_pool)
        allow(client_pool).to receive(:evict).and_call_original

        expect {
          Async do
            client.make_request(request, request_id)
          end.wait
        }.to raise_error(Errno::ECONNABORTED)

        expect(client_pool).to have_received(:evict).with("https://api.example.com/users")
      end
    end

    context "with response headers containing multiple values" do
      it "converts headers to hash with string values" do
        stub_request(:get, "https://api.example.com/users")
          .to_return(
            status: 200,
            body: "OK",
            headers: {
              "Content-Type" => "application/json",
              "X-Custom-Header" => "value1, value2",
              "Cache-Control" => "no-cache, no-store"
            }
          )

        result = Async do
          client.make_request(request, request_id)
        end.wait

        expect(result[:headers]["content-type"]).to eq("application/json")
        expect(result[:headers]["x-custom-header"]).to match(/value1.*value2/)
        expect(result[:headers]["cache-control"]).to match(/no-cache.*no-store/)
      end
    end
  end

  describe "#close" do
    let(:close_request) do
      PatientHttp::Request.new(
        :get,
        "https://api.example.com/users"
      )
    end

    it "closes the client pool" do
      stub_request(:get, "https://api.example.com/users")
        .to_return(status: 200, body: "OK")

      Async do
        client.make_request(close_request, request_id)
      end.wait

      expect { client.close }.not_to raise_error
    end
  end
end
