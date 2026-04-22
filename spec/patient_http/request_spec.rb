# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::Request do
  describe "#initialize" do
    it "creates a request with valid parameters" do
      request = described_class.new(
        :get,
        "https://api.example.com/users",
        headers: {"Authorization" => "Bearer token"},
        body: nil,
        timeout: 30
      )

      expect(request.http_method).to eq(:get)
      expect(request.url).to eq("https://api.example.com/users")
      expect(request.headers.to_h).to eq("authorization" => "Bearer token")
      expect(request.body).to be_nil
      expect(request.timeout).to eq(30)
    end

    it "accepts a URI object for url" do
      uri = URI("https://api.example.com/users")
      request = described_class.new(:get, uri)

      expect(request.url).to eq(uri.to_s)
    end

    it "accepts max_redirects parameter" do
      request = described_class.new(:get, "https://api.example.com", max_redirects: 10)
      expect(request.max_redirects).to eq(10)
    end

    it "allows max_redirects of 0 to disable redirects" do
      request = described_class.new(:get, "https://api.example.com", max_redirects: 0)
      expect(request.max_redirects).to eq(0)
    end

    it "defaults max_redirects to nil" do
      request = described_class.new(:get, "https://api.example.com")
      expect(request.max_redirects).to be_nil
    end

    context "with params" do
      it "serializes params and appends them to the url" do
        request = described_class.new(
          :get,
          "https://api.example.com/users",
          params: {page: 1, q: "hello world"}
        )

        expect(request.url).to eq("https://api.example.com/users?page=1&q=hello+world")
      end

      it "merges params with existing query params on the url" do
        request = described_class.new(
          :get,
          "https://api.example.com/users?active=true",
          params: {page: 1}
        )

        expect(request.url).to eq("https://api.example.com/users?active=true&page=1")
      end

      it "keeps url unchanged when params is nil" do
        request = described_class.new(:get, "https://api.example.com/users?active=true", params: nil)

        expect(request.url).to eq("https://api.example.com/users?active=true")
      end
    end

    context "validation" do
      it "casts method to a symbol" do
        request = described_class.new("POST", "https://example.com")
        expect(request.http_method).to eq(:post)
      end

      it "validates method is a valid HTTP method" do
        expect do
          described_class.new(:invalid, "https://example.com")
        end.to raise_error(ArgumentError, /method must be one of/)
      end

      it "accepts all valid HTTP methods" do
        %i[get post put patch delete].each do |method|
          expect do
            described_class.new(method, "https://example.com")
          end.not_to raise_error
        end
      end

      it "validates url is present" do
        expect do
          described_class.new(:get, nil)
        end.to raise_error(ArgumentError, "url is required")
      end

      it "validates url is not empty" do
        expect do
          described_class.new(:get, "")
        end.to raise_error(ArgumentError, "url is required")
      end

      it "validates url is a String or URI" do
        expect do
          described_class.new(:get, 123)
        end.to raise_error(ArgumentError, "url must be a String or URI, got: Integer")
      end

      it "validates body is not allowed for GET requests" do
        expect do
          described_class.new(:get, "https://example.com", body: "some body")
        end.to raise_error(ArgumentError, "body is not allowed for GET requests")
      end

      it "validates body is not allowed for DELETE requests" do
        expect do
          described_class.new(:delete, "https://example.com", body: "some body")
        end.to raise_error(ArgumentError, "body is not allowed for DELETE requests")
      end

      it "validates body must be a String when provided" do
        expect do
          described_class.new(:post, "https://example.com", body: {data: "value"})
        end.to raise_error(ArgumentError, "body must be a String, got: Hash")
      end

      it "allows nil body for POST requests" do
        expect do
          described_class.new(:post, "https://example.com", body: nil)
        end.not_to raise_error
      end

      it "allows String body for POST requests" do
        expect do
          described_class.new(:post, "https://example.com", body: '{"data":"value"}')
        end.not_to raise_error
      end
    end
  end

  describe "#as_json" do
    it "returns a hash representation of the request" do
      request = described_class.new(
        :post,
        "https://api.example.com/data",
        headers: {"Content-Type" => "application/json"},
        body: '{"key":"value"}',
        timeout: 15,
        max_redirects: 5
      )
      json = request.as_json
      expect(json).to eq(
        "http_method" => "post",
        "url" => "https://api.example.com/data",
        "headers" => {"content-type" => "application/json"},
        "body" => {"encoding" => "text", "value" => '{"key":"value"}', "charset" => "UTF-8"},
        "timeout" => 15,
        "max_redirects" => 5
      )
    end

    it "can reload the object from the json representation" do
      original_request = described_class.new(
        :put,
        "https://api.example.com/update",
        headers: {"Accept" => "application/json"},
        body: '{"update":"data"}',
        timeout: 20,
        max_redirects: 3
      )
      json = original_request.as_json
      reloaded_request = described_class.load(json)
      expect(reloaded_request.http_method).to eq(original_request.http_method)
      expect(reloaded_request.url).to eq(original_request.url)
      expect(reloaded_request.headers.to_h).to eq(original_request.headers.to_h)
      expect(reloaded_request.body).to eq(original_request.body)
      expect(reloaded_request.timeout).to eq(original_request.timeout)
      expect(reloaded_request.max_redirects).to eq(original_request.max_redirects)
    end
  end
end
