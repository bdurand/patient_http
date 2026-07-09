# frozen_string_literal: true

require "spec_helper"

RSpec.describe PatientHttp::RequestTask do
  let(:request) do
    PatientHttp::Request.new(:get, "https://api.example.com/users")
  end

  let(:job_data) do
    {
      "class" => "TestWorker",
      "jid" => "job-123",
      "args" => [1, 2, 3],
      "queue" => "default",
      "retry" => true
    }
  end

  let(:task_handler) { TestTaskHandler.new(job_data) }

  let(:callback) { "TestCallback" }

  before do
    TestCallback.reset_calls!
  end

  describe "#initialize" do
    it "creates a task with required parameters" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      expect(task.request).to eq(request)
      expect(task.task_handler).to eq(task_handler)
      expect(task.callback).to eq(callback)
    end

    it "accepts optional callback_args as a hash" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback,
        callback_args: {user_id: 123, action: "fetch"}
      )

      expect(task.callback_args).to eq({"user_id" => 123, "action" => "fetch"})
    end

    it "defaults callback_args to an empty hash when not provided" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      expect(task.callback_args).to eq({})
    end

    it "accepts redirects array" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback,
        redirects: ["https://example.com/1", "https://example.com/2"]
      )

      expect(task.redirects).to eq(["https://example.com/1", "https://example.com/2"])
    end

    it "defaults redirects to empty array" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      expect(task.redirects).to eq([])
    end

    it "uses request max_redirects when set" do
      request_with_redirects = PatientHttp::Request.new(:get, "https://api.example.com", max_redirects: 3)
      task = described_class.new(
        request: request_with_redirects,
        task_handler: task_handler,
        callback: callback
      )

      expect(task.max_redirects).to eq(3)
    end

    it "uses config max_redirects as fallback" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      expect(task.max_redirects).to eq(5)
    end

    it "generates a unique ID" do
      task1 = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )
      task2 = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      expect(task1.id).to be_a(String)
      expect(task2.id).to be_a(String)
      expect(task1.id).not_to eq(task2.id)
    end

    it "initializes timing attributes to nil" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      expect(task.enqueued_at).to be_nil
      expect(task.started_at).to be_nil
      expect(task.completed_at).to be_nil
    end

    it "accepts a Class for callback and stores its name" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: TestCallback
      )

      expect(task.callback).to eq("TestCallback")
    end
  end

  describe "#enqueued_duration" do
    it "returns nil when not yet enqueued" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      expect(task.enqueued_duration).to be_nil
    end
  end

  describe "#duration" do
    it "returns nil when not yet started" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      expect(task.duration).to be_nil
    end
  end

  describe "#retry" do
    it "delegates to the task handler" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      result = task.retry
      expect(result).to start_with("retry-")
      expect(task_handler.retries.size).to eq(1)
      expect(task_handler.retries.first).to eq(job_data)
    end
  end

  describe "#completed!" do
    it "calls task_handler on_complete with response" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback,
        callback_args: {"user_id" => 123, "action" => "fetch"}
      )
      task.started!

      response = task.build_response(
        status: 200,
        headers: {},
        body: "OK"
      )

      task.completed!(response)
      expect(task.response).to eq(response)
      expect(task.success?).to be(true)

      # Should call task_handler on_complete
      expect(task_handler.completions.size).to eq(1)
      completion = task_handler.completions.first
      expect(completion[:response]).to eq(response)
      expect(completion[:response].callback_args.as_json).to eq({"user_id" => 123, "action" => "fetch"})
      expect(completion[:callback]).to eq(callback)
      expect(task.duration).to be > 0
      expect(task.completed_at).not_to be_nil
    end

    it "uses empty callback_args when not provided" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      response = PatientHttp::Response.new(
        status: 200,
        headers: {},
        body: "OK",
        request_id: task.id,
        duration: 0.5,
        url: "https://api.example.com/users",
        http_method: :get
      )
      task.started!
      sleep(0.001)

      task.completed!(response)
      expect(task_handler.completions.size).to eq(1)
      completion = task_handler.completions.first
      expect(completion[:response].callback_args.as_json).to eq({})
    end
  end

  describe "#error!" do
    it "calls task_handler on_error with error" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback,
        callback_args: {"user_id" => 123, "action" => "fetch"}
      )

      exception = StandardError.new("Something went wrong")
      task.started!
      sleep(0.001)

      task.error!(exception)
      expect(task.error).to eq(exception)
      expect(task.error?).to be(true)

      # Should call task_handler on_error
      expect(task_handler.errors.size).to eq(1)
      error_entry = task_handler.errors.first
      expect(error_entry[:error]).to be_a(PatientHttp::RequestError)
      expect(error_entry[:error].callback_args.as_json).to eq({"user_id" => 123, "action" => "fetch"})
      expect(error_entry[:callback]).to eq(callback)
      expect(task.duration).to be > 0
      expect(task.completed_at).not_to be_nil
    end

    it "uses empty callback_args when not provided" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      exception = StandardError.new("Something went wrong")

      task.error!(exception)
      expect(task_handler.errors.size).to eq(1)
      error_entry = task_handler.errors.first
      expect(error_entry[:error].callback_args.as_json).to eq({})
    end
  end

  describe "#redirect_task" do
    let(:post_request) do
      PatientHttp::Request.new(:post, "https://api.example.com/submit", body: '{"data":"value"}', timeout: 30)
    end

    it "creates a new task for the redirect URL" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      redirect_task = task.redirect_task(location: "https://api.example.com/new-location", status: 302)

      expect(redirect_task).to be_a(described_class)
      expect(redirect_task.request.url).to eq("https://api.example.com/new-location")
      expect(redirect_task.id).not_to eq(task.id)
    end

    it "adds the original URL to the redirects chain" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback,
        redirects: ["https://example.com/first"]
      )

      redirect_task = task.redirect_task(location: "https://api.example.com/third", status: 302)

      expect(redirect_task.redirects).to eq(["https://example.com/first", "https://api.example.com/users"])
    end

    it "preserves callback and callback_args" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback,
        callback_args: {"user_id" => 123}
      )

      redirect_task = task.redirect_task(location: "https://api.example.com/new", status: 301)

      expect(redirect_task.callback).to eq(callback)
      expect(redirect_task.callback_args).to eq({"user_id" => 123})
    end

    it "preserves max_redirects setting from request" do
      request_with_max = PatientHttp::Request.new(:get, "https://api.example.com/users", max_redirects: 3)
      task = described_class.new(
        request: request_with_max,
        task_handler: task_handler,
        callback: callback
      )

      redirect_task = task.redirect_task(location: "https://api.example.com/new", status: 302)

      expect(redirect_task.max_redirects).to eq(3)
    end

    it "preserves preprocessors on same-origin redirects" do
      request = PatientHttp::Request.new(:get, "https://api.example.com/users", preprocessors: :signer)
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      redirect_task = task.redirect_task(location: "https://api.example.com/new-location", status: 302)

      expect(redirect_task.request.preprocessors).to eq(["signer"])
    end

    it "drops preprocessors on cross-origin redirects" do
      request = PatientHttp::Request.new(:get, "https://api.example.com/users", preprocessors: :signer)
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      redirect_task = task.redirect_task(location: "https://other.example.com/new-location", status: 302)

      expect(redirect_task.request.preprocessors).to eq([])
    end

    context "with 301, 302, 303 redirects" do
      it "converts POST to GET and removes body for 301" do
        task = described_class.new(
          request: post_request,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "https://api.example.com/new", status: 301)

        expect(redirect_task.request.http_method).to eq(:get)
        expect(redirect_task.request.body).to be_nil
      end

      it "converts POST to GET and removes body for 302" do
        task = described_class.new(
          request: post_request,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "https://api.example.com/new", status: 302)

        expect(redirect_task.request.http_method).to eq(:get)
        expect(redirect_task.request.body).to be_nil
      end

      it "converts POST to GET and removes body for 303" do
        task = described_class.new(
          request: post_request,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "https://api.example.com/new", status: 303)

        expect(redirect_task.request.http_method).to eq(:get)
        expect(redirect_task.request.body).to be_nil
      end
    end

    context "with 307, 308 redirects" do
      it "preserves method and body for 307" do
        task = described_class.new(
          request: post_request,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "https://api.example.com/new", status: 307)

        expect(redirect_task.request.http_method).to eq(:post)
        expect(redirect_task.request.body).to eq('{"data":"value"}')
      end

      it "preserves method and body for 308" do
        task = described_class.new(
          request: post_request,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "https://api.example.com/new", status: 308)

        expect(redirect_task.request.http_method).to eq(:post)
        expect(redirect_task.request.body).to eq('{"data":"value"}')
      end
    end

    context "with relative URLs" do
      it "resolves relative URL against base URL" do
        task = described_class.new(
          request: request,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "/new-path", status: 302)

        expect(redirect_task.request.url).to eq("https://api.example.com/new-path")
      end

      it "resolves relative URL with query string" do
        task = described_class.new(
          request: request,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "/search?q=test", status: 302)

        expect(redirect_task.request.url).to eq("https://api.example.com/search?q=test")
      end
    end

    context "with absolute URLs" do
      it "uses absolute URL directly" do
        task = described_class.new(
          request: request,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "https://other.example.com/path", status: 302)

        expect(redirect_task.request.url).to eq("https://other.example.com/path")
      end
    end

    context "with sensitive headers on cross-origin redirects" do
      let(:request_with_auth) do
        PatientHttp::Request.new(
          :get,
          "https://api.example.com/users",
          headers: {
            "Authorization" => "Bearer secret-token",
            "Cookie" => "session=abc123",
            "Accept" => "application/json"
          }
        )
      end

      it "preserves all headers on same-origin redirect" do
        task = described_class.new(
          request: request_with_auth,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "https://api.example.com/new-path", status: 302)

        expect(redirect_task.request.headers["authorization"]).to eq("Bearer secret-token")
        expect(redirect_task.request.headers["cookie"]).to eq("session=abc123")
        expect(redirect_task.request.headers["accept"]).to eq("application/json")
      end

      it "strips authorization and cookie headers on cross-origin redirect (different host)" do
        task = described_class.new(
          request: request_with_auth,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "https://other.example.com/path", status: 302)

        expect(redirect_task.request.headers["authorization"]).to be_nil
        expect(redirect_task.request.headers["cookie"]).to be_nil
        expect(redirect_task.request.headers["accept"]).to eq("application/json")
      end

      it "strips sensitive headers on cross-origin redirect (scheme change)" do
        task = described_class.new(
          request: request_with_auth,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "http://api.example.com/path", status: 302)

        expect(redirect_task.request.headers["authorization"]).to be_nil
        expect(redirect_task.request.headers["cookie"]).to be_nil
        expect(redirect_task.request.headers["accept"]).to eq("application/json")
      end

      it "strips sensitive headers on cross-origin redirect (different port)" do
        task = described_class.new(
          request: request_with_auth,
          task_handler: task_handler,
          callback: callback
        )

        redirect_task = task.redirect_task(location: "https://api.example.com:8443/path", status: 302)

        expect(redirect_task.request.headers["authorization"]).to be_nil
        expect(redirect_task.request.headers["cookie"]).to be_nil
        expect(redirect_task.request.headers["accept"]).to eq("application/json")
      end
    end
  end

  describe "#original_id" do
    it "returns task ID if there were no redirects" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      expect(task.original_id).to eq(task.id)
    end

    it "returns the original task ID for redirect tasks" do
      task = described_class.new(
        request: request,
        task_handler: task_handler,
        callback: callback
      )

      redirect_task = task.redirect_task(location: "https://api.example.com/new", status: 302)

      expect(redirect_task.original_id).to eq(task.id)
    end
  end
end
