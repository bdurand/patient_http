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
      [301, 302, 303, 307, 308].each do |status|
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
      [300, 304, 305, 306, 399].each do |status|
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
