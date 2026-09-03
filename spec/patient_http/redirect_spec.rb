# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Redirect handling" do
  let(:config) { PatientHttp::Configuration.new(max_redirects: 5) }
  let(:processor) { PatientHttp::Processor.new(config) }

  let(:request) { PatientHttp::Request.new(:get, "https://example.com/start") }
  let(:job_data) do
    {
      "class" => "TestWorker",
      "jid" => "job-123",
      "args" => [1, 2, 3],
      "queue" => "default"
    }
  end
  let(:task_handler) { TestTaskHandler.new(job_data) }

  describe "redirect status codes" do
    describe "followable redirects" do
      [300, 301, 302, 303, 307, 308].each do |status|
        it "follows #{status} redirects" do
          task = PatientHttp::RequestTask.new(
            request: request,
            task_handler: task_handler,
            callback: TestCallback
          )

          response_data = {
            status: status,
            headers: {"location" => "https://example.com/new"},
            body: nil
          }

          expect(processor.send(:should_follow_redirect?, task, response_data)).to be true
        end
      end
    end

    describe "non-followable redirects" do
      [304, 305, 306, 399].each do |status|
        it "does not follow #{status} status" do
          task = PatientHttp::RequestTask.new(
            request: request,
            task_handler: task_handler,
            callback: TestCallback
          )

          response_data = {
            status: status,
            headers: {"location" => "https://example.com/new"},
            body: nil
          }

          expect(processor.send(:should_follow_redirect?, task, response_data)).to be false
        end
      end
    end
  end

  describe "Location header" do
    it "does not follow redirect without Location header" do
      task = PatientHttp::RequestTask.new(
        request: request,
        task_handler: task_handler,
        callback: TestCallback
      )

      response_data = {
        status: 302,
        headers: {},
        body: nil
      }

      expect(processor.send(:should_follow_redirect?, task, response_data)).to be false
    end

    it "does not follow redirect with empty Location header" do
      task = PatientHttp::RequestTask.new(
        request: request,
        task_handler: task_handler,
        callback: TestCallback
      )

      response_data = {
        status: 302,
        headers: {"location" => ""},
        body: nil
      }

      expect(processor.send(:should_follow_redirect?, task, response_data)).to be false
    end
  end

  describe "max_redirects = 0" do
    it "does not follow redirects when max_redirects is 0" do
      request_no_redirects = PatientHttp::Request.new(:get, "https://example.com/start", max_redirects: 0)
      task = PatientHttp::RequestTask.new(
        request: request_no_redirects,
        task_handler: task_handler,
        callback: TestCallback
      )

      response_data = {
        status: 302,
        headers: {"location" => "https://example.com/new"},
        body: nil
      }

      expect(processor.send(:should_follow_redirect?, task, response_data)).to be false
    end
  end

  describe "redirect_downgrade" do
    def redirect_response(status)
      {status: status, headers: {"location" => "https://example.com/new"}, body: nil}
    end

    def task_for(request)
      PatientHttp::RequestTask.new(request: request, task_handler: task_handler, callback: TestCallback)
    end

    context "when the configuration disables downgrades" do
      let(:processor) { PatientHttp::Processor.new(PatientHttp::Configuration.new(redirect_downgrade: false)) }

      it "does not follow a 302 for a POST since the method would change" do
        task = task_for(PatientHttp::Request.new(:post, "https://example.com/start", body: "data"))
        expect(processor.send(:should_follow_redirect?, task, redirect_response(302))).to be false
      end

      it "does not follow a 303 for a QUERY since the method would change" do
        task = task_for(PatientHttp::Request.new(:query, "https://example.com/start", body: "data"))
        expect(processor.send(:should_follow_redirect?, task, redirect_response(303))).to be false
      end

      it "follows a 302 for a PUT since the method is preserved" do
        task = task_for(PatientHttp::Request.new(:put, "https://example.com/start", body: "data"))
        expect(processor.send(:should_follow_redirect?, task, redirect_response(302))).to be true
      end

      it "follows a 307 for a POST since the method is preserved" do
        task = task_for(PatientHttp::Request.new(:post, "https://example.com/start", body: "data"))
        expect(processor.send(:should_follow_redirect?, task, redirect_response(307))).to be true
      end

      it "follows a 303 for a HEAD since the method is preserved" do
        task = task_for(PatientHttp::Request.new(:head, "https://example.com/start"))
        expect(processor.send(:should_follow_redirect?, task, redirect_response(303))).to be true
      end

      it "lets the request enable downgrades" do
        task = task_for(PatientHttp::Request.new(:post, "https://example.com/start", body: "data", redirect_downgrade: true))
        expect(processor.send(:should_follow_redirect?, task, redirect_response(302))).to be true
      end
    end

    context "when the configuration allows downgrades" do
      it "follows a 302 for a POST" do
        task = task_for(PatientHttp::Request.new(:post, "https://example.com/start", body: "data"))
        expect(processor.send(:should_follow_redirect?, task, redirect_response(302))).to be true
      end

      it "lets the request disable downgrades" do
        task = task_for(PatientHttp::Request.new(:post, "https://example.com/start", body: "data", redirect_downgrade: false))
        expect(processor.send(:should_follow_redirect?, task, redirect_response(302))).to be false
      end
    end
  end

  describe "RedirectHelper.redirect_method" do
    all_methods = %i[get head post put patch delete query]

    [300, 307, 308].each do |status|
      it "preserves every method for #{status}" do
        all_methods.each do |method|
          expect(PatientHttp::RedirectHelper.redirect_method(method, status)).to eq(method)
        end
      end
    end

    [301, 302].each do |status|
      it "changes only POST to GET for #{status}" do
        expect(PatientHttp::RedirectHelper.redirect_method(:post, status)).to eq(:get)
        (all_methods - [:post]).each do |method|
          expect(PatientHttp::RedirectHelper.redirect_method(method, status)).to eq(method)
        end
      end
    end

    it "preserves GET and HEAD and changes every other method to GET for 303" do
      expect(PatientHttp::RedirectHelper.redirect_method(:get, 303)).to eq(:get)
      expect(PatientHttp::RedirectHelper.redirect_method(:head, 303)).to eq(:head)
      (all_methods - %i[get head]).each do |method|
        expect(PatientHttp::RedirectHelper.redirect_method(method, 303)).to eq(:get)
      end
    end
  end

  describe "RedirectHelper.normalize_header_names" do
    it "downcases header names" do
      expect(PatientHttp::RedirectHelper.normalize_header_names(["X-Api-Key", :Cookie])).to eq(["x-api-key", "cookie"])
    end

    it "accepts a single value" do
      expect(PatientHttp::RedirectHelper.normalize_header_names("X-Api-Key")).to eq(["x-api-key"])
    end

    it "returns an empty array for nil" do
      expect(PatientHttp::RedirectHelper.normalize_header_names(nil)).to eq([])
    end

    it "rejects values that are not strings" do
      expect {
        PatientHttp::RedirectHelper.normalize_header_names([/^x-internal-/])
      }.to raise_error(ArgumentError, /must be strings/)
    end

    it "rejects empty header names" do
      expect {
        PatientHttp::RedirectHelper.normalize_header_names([""])
      }.to raise_error(ArgumentError, /cannot be empty/)
    end
  end

  describe "URL resolution" do
    it "resolves absolute URLs" do
      result = processor.send(:resolve_redirect_url, "https://example.com/page", "https://other.com/new")
      expect(result).to eq("https://other.com/new")
    end

    it "resolves relative paths" do
      result = processor.send(:resolve_redirect_url, "https://example.com/page", "/new-path")
      expect(result).to eq("https://example.com/new-path")
    end

    it "resolves relative paths with query strings" do
      result = processor.send(:resolve_redirect_url, "https://example.com/page", "/search?q=test")
      expect(result).to eq("https://example.com/search?q=test")
    end

    it "resolves relative paths preserving scheme and host" do
      result = processor.send(:resolve_redirect_url, "https://api.example.com:8080/v1/users", "/v2/users")
      expect(result).to eq("https://api.example.com:8080/v2/users")
    end
  end
end
