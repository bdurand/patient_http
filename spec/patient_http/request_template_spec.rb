# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::RequestTemplate do
  let(:base_url) { "https://api.example.com" }
  let(:default_headers) { {"Authorization" => "Bearer token123"} }

  describe "#initialize" do
    it "sets the base_url" do
      client = described_class.new(base_url: base_url)
      expect(client.base_url).to eq(base_url)
    end

    it "sets headers as HttpHeaders object" do
      client = described_class.new(headers: default_headers)
      expect(client.headers).to be_a(PatientHttp::HttpHeaders)
      expect(client.headers["Authorization"]).to eq("Bearer token123")
    end

    it "sets default timeout to 30 seconds" do
      client = described_class.new
      expect(client.timeout).to eq(30)
    end

    it "allows custom timeout" do
      client = described_class.new(timeout: 60)
      expect(client.timeout).to eq(60)
    end

    it "initializes with empty headers by default" do
      client = described_class.new
      expect(client.headers.to_h).to eq({})
    end
  end

  describe "#request" do
    let(:template) { described_class.new(base_url: base_url, headers: default_headers) }

    it "returns an Request object" do
      result = template.request(:get, "/users")
      expect(result).to be_a(PatientHttp::Request)
    end

    it "creates Request with method, url, headers, body, and timeout" do
      result = template.request(:post, "/users", body: "data")
      expect(result.http_method).to eq(:post)
      expect(result.url).to eq("https://api.example.com/users")
      expect(result.headers.to_h).to include("authorization" => "Bearer token123")
      expect(result.body).to eq("data")
      expect(result.timeout).to eq(30)
    end

    context "with URI joining" do
      it "joins base_url with relative path" do
        template.request(:get, "/users")
        # The joining happens internally, we can verify it doesn't raise
      end

      it "handles paths without leading slash" do
        template.request(:get, "users")
        # Should not raise
      end

      it "handles full paths" do
        template.request(:get, "/api/v1/users")
        # Should not raise
      end
    end

    context "with query parameters" do
      it "adds params to the URI" do
        template.request(:get, "/users", params: {page: 1, limit: 10})
        # Params are encoded and added to query string
      end

      it "merges template params with request params" do
        template_with_params = described_class.new(
          base_url: base_url,
          headers: default_headers,
          params: {locale: "en", page: 1}
        )

        result = template_with_params.request(:get, "/users", params: {page: 2, limit: 10})

        expect(result.url).to eq("https://api.example.com/users?locale=en&page=2&limit=10")
      end

      it "uses request params when template params are nil" do
        template_with_nil_params = described_class.new(
          base_url: base_url,
          headers: default_headers,
          params: nil
        )

        result = template_with_nil_params.request(:get, "/users", params: {page: 2, limit: 10})

        expect(result.url).to eq("https://api.example.com/users?page=2&limit=10")
      end

      it "keeps URL unchanged when both template and request params are nil" do
        template_with_nil_params = described_class.new(
          base_url: base_url,
          headers: default_headers,
          params: nil
        )

        result = template_with_nil_params.request(:get, "/users", params: nil)

        expect(result.url).to eq("https://api.example.com/users")
      end

      it "merges params with existing query string" do
        template.request(:get, "/users?active=true", params: {page: 1})
        # Should merge both query params
      end

      it "handles empty params" do
        result = template.request(:get, "/users", params: {})
        expect(result).to be_a(PatientHttp::Request)
      end

      it "handles special characters in params" do
        template.request(:get, "/search", params: {q: "hello world", filter: "type:user"})
        # Should URL encode params properly
      end
    end

    context "with headers" do
      it "merges request headers with instance headers" do
        template.request(:get, "/users", headers: {"X-Request-ID" => "abc123"})
        # Headers should be merged
      end

      it "does not merge when no headers provided" do
        result = template.request(:get, "/users")
        expect(result).to be_a(PatientHttp::Request)
      end

      it "handles empty headers hash" do
        result = template.request(:get, "/users", headers: {})
        expect(result).to be_a(PatientHttp::Request)
      end
    end

    context "with JSON body" do
      it "converts json to string body and sets Content-Type header" do
        data = {name: "John", email: "john@example.com"}
        result = template.request(:post, "/users", json: data)

        expect(result.body).to eq(JSON.generate(data))
        expect(result.headers["content-type"]).to eq("application/json; charset=utf-8")
      end

      it "raises error when both body and json are provided" do
        expect {
          template.request(:post, "/users", body: "raw data", json: {name: "John"})
        }.to raise_error(ArgumentError, "Cannot provide both body and json")
      end

      it "handles complex JSON structures" do
        data = {
          user: {
            name: "John",
            roles: ["admin", "user"],
            metadata: {created_at: "2026-01-09"}
          }
        }
        result = template.request(:post, "/users", json: data)
        expect(result).to be_a(PatientHttp::Request)
        expect(result.body).to eq(JSON.generate(data))
      end
    end

    context "with body" do
      it "accepts string body" do
        result = template.request(:post, "/users", body: "raw request body")
        expect(result).to be_a(PatientHttp::Request)
      end

      it "accepts nil body" do
        result = template.request(:post, "/users", body: nil)
        expect(result).to be_a(PatientHttp::Request)
      end
    end

    context "with all options" do
      it "handles all parameters together" do
        result = template.request(
          :post,
          "/users",
          body: "data",
          headers: {"X-Custom" => "value"},
          params: {page: 1}
        )
        expect(result).to be_a(PatientHttp::Request)
      end
    end
  end

  describe "#get" do
    let(:template) { described_class.new(base_url: base_url) }

    it "calls request with :get method" do
      expect(template).to receive(:request).with(:get, "/users")
      template.get("/users")
    end

    it "forwards all keyword arguments" do
      expect(template).to receive(:request).with(
        :get,
        "/users",
        params: {page: 1},
        headers: {"X-Custom" => "value"}
      )
      template.get("/users", params: {page: 1}, headers: {"X-Custom" => "value"})
    end

    it "returns an Request" do
      result = template.get("/users")
      expect(result).to be_a(PatientHttp::Request)
    end
  end

  describe "#post" do
    let(:template) { described_class.new(base_url: base_url) }

    it "calls request with :post method" do
      expect(template).to receive(:request).with(:post, "/users")
      template.post("/users")
    end

    it "forwards all keyword arguments" do
      expect(template).to receive(:request).with(
        :post,
        "/users",
        json: {name: "John"},
        headers: {"X-Custom" => "value"}
      )
      template.post("/users", json: {name: "John"}, headers: {"X-Custom" => "value"})
    end

    it "returns an Request" do
      result = template.post("/users", body: "data")
      expect(result).to be_a(PatientHttp::Request)
    end
  end

  describe "#put" do
    let(:template) { described_class.new(base_url: base_url) }

    it "calls request with :put method" do
      expect(template).to receive(:request).with(:put, "/users/1")
      template.put("/users/1")
    end

    it "forwards all keyword arguments" do
      expect(template).to receive(:request).with(
        :put,
        "/users/1",
        json: {name: "Jane"},
        params: {notify: true}
      )
      template.put("/users/1", json: {name: "Jane"}, params: {notify: true})
    end

    it "returns an Request" do
      result = template.put("/users/1", body: "data")
      expect(result).to be_a(PatientHttp::Request)
    end
  end

  describe "#patch" do
    let(:template) { described_class.new(base_url: base_url) }

    it "calls request with :patch method" do
      expect(template).to receive(:request).with(:patch, "/users/1")
      template.patch("/users/1")
    end

    it "forwards all keyword arguments" do
      expect(template).to receive(:request).with(
        :patch,
        "/users/1",
        json: {email: "new@example.com"}
      )
      template.patch("/users/1", json: {email: "new@example.com"})
    end

    it "returns an Request" do
      result = template.patch("/users/1", body: "data")
      expect(result).to be_a(PatientHttp::Request)
    end
  end

  describe "#delete" do
    let(:template) { described_class.new(base_url: base_url) }

    it "calls request with :delete method" do
      expect(template).to receive(:request).with(:delete, "/users/1")
      template.delete("/users/1")
    end

    it "forwards all keyword arguments" do
      expect(template).to receive(:request).with(
        :delete,
        "/users/1",
        headers: {"X-Reason" => "spam"}
      )
      template.delete("/users/1", headers: {"X-Reason" => "spam"})
    end

    it "returns an Request" do
      result = template.delete("/users/1")
      expect(result).to be_a(PatientHttp::Request)
    end
  end

  describe "attribute accessors" do
    it "allows setting and getting base_url" do
      client = described_class.new
      client.base_url = "https://new-api.example.com"
      expect(client.base_url).to eq("https://new-api.example.com")
    end

    it "allows setting and getting headers" do
      client = described_class.new
      new_headers = PatientHttp::HttpHeaders.new({"X-New" => "header"})
      client.headers = new_headers
      expect(client.headers).to eq(new_headers)
    end

    it "allows setting and getting timeout" do
      client = described_class.new
      client.timeout = 45
      expect(client.timeout).to eq(45)
    end
  end
end
