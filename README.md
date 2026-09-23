# PatientHttp

[![Continuous Integration](https://github.com/bdurand/patient_http/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http.svg)](https://badge.fury.io/rb/patient_http)

*Built for APIs that like to think.*

Generic async HTTP connection pool for Ruby applications using Fiber-based concurrency.

## Motivation

Applications that make HTTP requests from within threaded environments often find that threads block waiting for I/O. A single slow API response holds an entire thread hostage, preventing it from doing other work. When many threads are blocked on HTTP I/O simultaneously, throughput collapses.

PatientHttp solves this by running HTTP requests in a dedicated processor thread that uses Ruby's Fiber scheduler for non-blocking I/O. Application threads hand off HTTP requests to the processor and return immediately. The processor handles hundreds of concurrent HTTP connections using fibers, then notifies the application when responses arrive via a pluggable callback mechanism.

This design keeps application threads free to do other work while HTTP requests are in flight.

## Quick Start

PatientHttp needs somewhere to run requests and something to deliver results to. Pair it with the integration for your job system and both are handled for you:

- [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) for Sidekiq
- [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) for Solid Queue

For large language model requests, [patient_llm](https://github.com/bdurand/patient_llm) builds on top of this gem. LLM requests taking much longer than typical HTTP requests was the original motivation for PatientHttp.

### 1. Install

Add the integration for your job system to your Gemfile. It depends on this gem, so you do not need to list `patient_http` separately.

```ruby
gem "patient_http-sidekiq"
```

That is the whole setup. Loading the gem registers the request handler and hooks the processor into your job system's startup and shutdown. There is no initializer to write and no method you have to remember to call.

### 2. Write a callback class

Results arrive in a class with `on_complete` and `on_error` instance methods. It runs as a background job, so it can do real work.

```ruby
class FetchUserCallback
  def on_complete(response)
    user_id = response.callback_args[:user_id]
    User.find(user_id).update!(external_data: response.json)
  end

  def on_error(error)
    user_id = error.callback_args[:user_id]
    Rails.logger.error("Failed to fetch user #{user_id}: #{error.message}")
  end
end
```

### 3. Make requests

```ruby
PatientHttp.get(
  "https://api.example.com/users/123",
  callback: FetchUserCallback,
  callback_args: {user_id: 123}
)
```

The call returns immediately. The request runs on the async processor, and when the response arrives your callback is invoked in a background job.

To change any default, see [Configuration](#configuration). Every option is optional.

### Working without a job system

In consoles, tests, and development environments with no job system, run requests inline instead:

```ruby
PatientHttp.inline!
```

Every request made through the `PatientHttp` interface then runs immediately on the calling thread, through the full request lifecycle (timeouts, redirects, error wrapping), and invokes its callback before returning.

```ruby
PatientHttp.inline!
PatientHttp.get("https://api.example.com/users/123", callback: FetchUserCallback)
# FetchUserCallback#on_complete has already been invoked by this point
```

Callbacks can make further requests; those execute inline as well. Use `PatientHttp.inline?` to check whether the inline handler is registered, and `PatientHttp.execute_inline(request:, callback:)` to run a single request inline without registering a handler.

## Making Requests

The `PatientHttp` module provides a method for each HTTP verb: `get`, `head`, `post`, `put`, `patch`, `delete`, and `query`. They all accept the same options, and `PatientHttp.request` takes the method as its first argument.

```ruby
PatientHttp.post(
  "https://api.example.com/users",
  json: {name: "John", email: "john@example.com"},
  callback: CreateUserCallback,
  callback_args: {source: "signup"}
)
```

| Option | Description |
| --- | --- |
| `callback:` | Required. Callback class or its name. |
| `callback_args:` | Data passed through to the callback on the response or error. |
| `headers:` | Request headers. |
| `body:` | Raw request body. |
| `json:` | Object serialized as a JSON body. Cannot be combined with `body:`. |
| `params:` | Query parameters appended to the URL. |
| `timeout:` | Request timeout in seconds. |
| `raise_error_responses:` | Treat non-2xx responses as errors. |
| `max_redirects:` | Redirect limit for this request. 0 disables redirects. |
| `follow_method_changing_redirects:` | See [Redirects](#redirects). |
| `redirect_strip_headers:` | Header names never sent to a redirect target. |
| `preprocessors:` | Names of registered [preprocessors](#request-preprocessors) to apply. |
| `processor:` | Name of the processor to run the request on. See [Workload isolation](#workload-isolation). |

Keeping your application code on these methods means it never names your job system, so moving from one to another is a Gemfile change.

### Handling HTTP error responses

By default, 4xx and 5xx responses are treated as completed requests and delivered to `on_complete`. Check the status with the helper methods:

```ruby
def on_complete(response)
  if response.success?         # 2xx
    process_data(response.json)
  elsif response.client_error? # 4xx
    handle_client_error(response)
  elsif response.server_error? # 5xx
    handle_server_error(response)
  end
end
```

To treat them as errors instead, pass `raise_error_responses: true`. The callback's `on_error` is then called with an `HttpError` that carries the response:

```ruby
PatientHttp.get("https://api.example.com/data", callback: ApiCallback, raise_error_responses: true)

def on_error(error)
  if error.is_a?(PatientHttp::HttpError)
    puts error.status           # HTTP status code
    puts error.url              # Request URL
    puts error.http_method      # HTTP method
    puts error.response.body    # Response body
  end
end
```

Set `raise_error_responses` in the configuration to make it the default for every request.

### Callback arguments

Pass data through the request and response cycle with `callback_args`:

```ruby
PatientHttp.get(
  "https://api.example.com/users/#{user_id}",
  callback: FetchUserCallback,
  callback_args: {user_id: user_id, requested_at: Time.now.iso8601}
)
```

They are available on both `Response` and `Error` objects, by symbol or string key:

```ruby
response.callback_args[:user_id]
response.callback_args["user_id"]
```

Callback args must contain only JSON-native types (`nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, `Hash`). Hash keys are converted to strings for serialization, including in nested hashes and hashes inside arrays.

### Request templates

For repeated requests to the same API, `RequestTemplate` shares a base URL, headers, and timeout:

```ruby
template = PatientHttp::RequestTemplate.new(
  base_url: "https://api.example.com",
  headers: {"Authorization" => PatientHttp.secret(:api_token)},
  timeout: 60
)

request = template.get("/users/123")
PatientHttp.execute(request: request, callback: FetchUserCallback)
```

Templates support all HTTP methods (`get`, `head`, `post`, `put`, `patch`, `delete`, `query`) and handle URL joining, header merging, and query parameter encoding.

### RequestHelper mixin

For classes that make many requests, include `PatientHttp::RequestHelper` to get `async_get`, `async_head`, `async_post`, `async_put`, `async_patch`, `async_delete`, `async_query`, and `async_request`. Declare a class-level `request_template` for shared options, and paths are resolved against its `base_url`.

```ruby
class ApiClient
  include PatientHttp::RequestHelper

  request_template(
    base_url: "https://api.example.com",
    headers: {"Authorization" => PatientHttp.secret(:api_token)},
    timeout: 60
  )

  def fetch_user(user_id)
    async_get("/users/#{user_id}", callback: FetchUserCallback, callback_args: {user_id: user_id})
  end

  def update_user(user_id, data)
    async_patch("/users/#{user_id}", json: data, callback: UpdateUserCallback, callback_args: {user_id: user_id})
  end
end
```

The `async_*` methods accept the same options as the `PatientHttp` module methods.

## Configuration

Configure through `PatientHttp.configure`, whichever job system you use. When an integration gem is loaded, this yields that integration's configuration, which carries its own options alongside the ones below. The same object is yielded every time, so several initializers can each contribute without overwriting one another.

Everything is optional; the defaults are shown.

```ruby
PatientHttp.configure do |config|
  # Maximum concurrent HTTP requests (default: 256)
  config.max_connections = 256

  # Maximum connections to any one host (default: nil, unlimited)
  config.max_connections_per_host = 32

  # Default timeout for HTTP requests in seconds (default: 60)
  config.request_timeout = 60

  # Timeout for graceful shutdown in seconds (default: 30)
  config.shutdown_timeout = 30

  # Maximum response body size in bytes (default: 1MB)
  config.max_response_size = 1024 * 1024

  # Default User-Agent header (default: "PatientHttp")
  config.user_agent = "MyApp/1.0"

  # Treat non-2xx responses as errors by default (default: false)
  config.raise_error_responses = false

  # Maximum redirects to follow (default: 5, 0 disables)
  config.max_redirects = 5

  # Follow redirects that must change the HTTP method, such as POST to GET on
  # a 302 (default: true). When false, those requests receive the redirect response.
  config.follow_method_changing_redirects = true

  # Header names (case insensitive) always stripped from redirected requests
  # (default: []). Authorization and Cookie are always stripped on cross-origin
  # redirects.
  config.redirect_strip_headers = ["X-Api-Key", "X-Internal-Token"]

  # Maximum number of hosts to maintain persistent connections for (default: 100)
  config.connection_pool_size = 100

  # Connection timeout in seconds (default: nil, uses request_timeout)
  config.connection_timeout = 10

  # TCP keepalive in seconds (default: nil, disabled)
  config.tcp_keepalive = 30

  # Timeout for server to acknowledge receipt of data in seconds.
  config.tcp_user_timeout = 30

  # HTTP/HTTPS proxy URL (default: nil)
  config.proxy_url = "http://proxy.example.com:8080"

  # Retries for failed requests (default: 3)
  config.retries = 3

  # Force the HTTP protocol to :http1 or :http2 (default: nil, negotiates with
  # the server, preferring HTTP/2 for HTTPS). Forcing :http1 also limits the TLS
  # ALPN advertisement to http/1.1, which can work around SSL-intercepting
  # proxies that mishandle HTTP/2.
  config.protocol = nil

  # Threads that decode responses and deliver results (default: 2)
  config.completion_threads = 2

  # Delivery retries before a result is reported as failed (default: 2)
  config.completion_retries = 2

  # Size in bytes above which payloads go to a payload store (default: 64KB)
  config.payload_store_threshold = 64 * 1024

  # Logger instance (default: Logger to STDERR at ERROR level)
  config.logger = Rails.logger
end
```

`PatientHttp.configuration` returns the same object outside a configure block.

### Workload isolation

Named processors are provided by the job system integration gems, so `config.processor` is only available when one of them is loaded.

By default all requests share one processor and one `max_connections` cap, so a burst of slow requests can consume the capacity that quick requests need. Named processors run independently, each with its own capacity, timeouts, and threads:

```ruby
PatientHttp.configure do |config|
  config.processor(:llm, max_connections: 200, request_timeout: 120)
  config.processor(:webhooks, max_connections: 64, request_timeout: 10)
end
```

Route a request with the `processor:` option, on the call or on the request itself:

```ruby
PatientHttp.post(url, callback: MyCallback, processor: :llm)
```

Profile options override the top-level configuration. Everything not overridden (secrets, preprocessors, payload stores, encryption, logger) is shared. The `:default` processor always exists. See the integration gem's documentation for how routing survives retries and crash recovery.

### Tuning tips

- **max_connections**: Each connection uses memory and file descriptors. A tuned system can handle thousands.
- **max_connections_per_host**: Bounds sockets per host (default unlimited). Set a value such as 32 for high-concurrency deployments so one host cannot consume every file descriptor. Verify the process file descriptor limit covers `max_connections` plus pooled idle host connections plus the application's own connections.
- **request_timeout**: Set based on expected API response times. AI/LLM APIs may need minutes.
- **connection_pool_size**: Increase for applications calling many different API hosts.
- **max_response_size**: Keeps memory usage bounded. Large responses may need a payload store. The limit applies to the inflated bytes of compressed responses.
- **Response compression**: Requests ask for `gzip` by default and the body is inflated on a completion worker thread. Set `accept-encoding` on a request to change this: `identity` skips compression, and any other encoding is delivered still encoded with its `content-encoding` header kept so you can decode it yourself.
- **completion_threads**: Number of threads that decode responses and deliver results (default 2). Increase when callbacks do heavier work (serialization, encryption) and completions back up behind them. Any value above 1 delivers results concurrently, so `TaskHandler` callbacks and completion-time observers must be thread-safe. Use 1 to serialize delivery.
- **completion_retries**: Delivery retries before a result is reported through `completion_failed` (default 2). A retry calls `on_complete`/`on_error` again, so a handler that raises *after* enqueuing its message delivers that message twice. Make handlers idempotent, or set `completion_retries: 0` to report the first failure without retrying.
- **shutdown_timeout**: Set below the process supervisor's termination window so the drain (including handed-off completions) finishes before a hard kill.

## Sensitive and Large Payloads

Requests and responses are serialized into your job queue so they can cross process boundaries. That raises two questions: what to do about values that should not be written there, and what to do about payloads too large to belong there.

Four features cover these, and they are complementary rather than alternatives:

| Use | When | Registered with |
| --- | --- | --- |
| [Secrets](#secrets) | A single sensitive header or query parameter, such as an API token | `config.register_secret` |
| [Preprocessors](#request-preprocessors) | A signature computed over the final request, such as AWS SigV4 | `config.register_preprocessor` |
| [Encryption](#encryption) | The request or response body itself is sensitive | `config.encryption_key` |
| [Payload stores](#payload-stores) | Payloads too large for the queue | `config.register_payload_store` |

Reach for secrets and preprocessors first: they keep sensitive values out of the queue entirely rather than encrypting them there. Use encryption when the payload itself is sensitive, and a payload store when size is the problem.

### Secrets

If you put an API token directly on a request, that value is written into your job queue. A secret lets you reference it by name instead. The serialized request stores only a marker (`{"$secret" => "name"}`); the value lives on the configuration, which exists on the processor side, and is resolved at the moment the request is sent.

Register secrets with a value or with a block that is evaluated each time the secret is resolved:

```ruby
PatientHttp.configure do |config|
  config.register_secret(:authorization, "Bearer #{ENV["API_TOKEN"]}")
  config.register_secret(:api_key) { ENV["MY_API_KEY"] }
end
```

You can also register at the module level, which is useful in a library or an initializer that loads before the rest of your configuration:

```ruby
PatientHttp.register_secret(:api_key) { ENV["MY_API_KEY"] }
```

Module-level secrets are applied to the configuration whenever it is created, so registration order does not matter. Use `PatientHttp.secret_registered?(name)` to check whether a secret is available.

Reference a secret anywhere you would put a sensitive header or query parameter value:

```ruby
PatientHttp.get(
  "https://api.example.com/data",
  callback: MyCallback,
  headers: {"Authorization" => PatientHttp.secret(:api_token)},
  params: {"api_key" => PatientHttp.secret(:api_key), "page" => 2}
)
```

The secret query parameter is kept out of the serialized URL while non-secret params like `page` are folded in as usual. The processor resolves both just before sending. A secret that is not registered raises `PatientHttp::SecretManager::SecretNotFoundError` through the normal request error path.

### Request preprocessors

Preprocessors modify a request just before it is sent, most usefully to sign it. Signing schemes like AWS SigV4 compute values over the final outgoing request and set multiple headers, which cannot be expressed as a static header value at build time.

Like secrets, preprocessors are registered on the configuration and referenced by name, so the signing logic and its credentials stay on the processor side and are never written to the queue.

```ruby
PatientHttp.configure do |config|
  config.register_preprocessor(:aws_sigv4) do |request|
    signer = Aws::Sigv4::Signer.new(
      service: "execute-api",
      region: "us-east-1",
      credentials_provider: Aws::CredentialProviderChain.new.resolve
    )
    signature = signer.sign_request(
      http_method: request.http_method.to_s.upcase,
      url: request.url,
      headers: request.headers.to_h,
      body: request.body.to_s
    )
    signature.headers.each { |name, value| request.headers[name] = value }
  end
end

PatientHttp.post("https://api.example.com/data", callback: MyCallback, json: {value: 1}, preprocessors: :aws_sigv4)
```

The argument is a `PatientHttp::OutgoingRequest`, a view of the request as it is about to be sent, after secret references have been resolved and the `x-request-id` and default `User-Agent` headers have been set. It exposes:

- `http_method`, `url`, and `body` (read-only; the URL includes any resolved secret query params)
- `headers`, mutable and case-insensitive
- `add_param(name, value)`, which appends a query parameter to the URL for signed-query-param schemes

Multiple preprocessors can be given as an array and run in order, each seeing the changes made before it. `RequestTemplate` and the `RequestHelper` mixin's `request_template` accept `preprocessors:` as a default. An unregistered name raises `PatientHttp::RequestPreparer::PreprocessorNotFoundError` through the normal request error path.

When redirects are followed, preprocessors re-run against each redirect URL so signatures stay valid. On cross-origin redirects they are dropped entirely, consistent with the stripping of `Authorization` and `Cookie` headers, so signed credentials are never sent to an unexpected origin.

### Encryption

When the request or response body itself is sensitive, encrypt it. The integration gems encrypt and decrypt at every queue boundary automatically once a key is configured.

The simplest option is `encryption_key`, which sets up [ActiveSupport::MessageEncryptor](https://api.rubyonrails.org/classes/ActiveSupport/MessageEncryptor.html) with AES-256-GCM:

```ruby
PatientHttp.configure do |config|
  config.encryption_key = ENV["PATIENT_HTTP_ENCRYPTION_KEY"]
end
```

Pass an array to rotate keys. The first encrypts new data and all of them are tried for decryption:

```ruby
config.encryption_key = [ENV["PATIENT_HTTP_ENCRYPTION_KEY"], ENV["PATIENT_HTTP_OLD_KEY"]]
```

For a different encryption library, provide callables that take and return raw bytes:

```ruby
config.encryption { |bytes| MyEncryption.encrypt(bytes) }
config.decryption { |bytes| MyEncryption.decrypt(bytes) }
```

Either form also accepts any object responding to `#call`.

Encrypted data is stored as `{"__encrypted__" => true, "value" => "<base64>"}`. The `Encryptor` JSON-serializes the original hash, passes the bytes to your callable, and Base64-encodes the result. Hashes without the `"__encrypted__"` key pass through unchanged, so data written before you turned encryption on continues to work.

If you write your own `TaskHandler`, see [Building a Custom Integration](#building-a-custom-integration) for how to wire encryption in yourself.

### Payload stores

Register a payload store and any serialized payload larger than `payload_store_threshold` is written there instead of into the job queue, and replaced with a lightweight reference that is resolved on demand. This keeps queue messages small without changing your application code.

```ruby
PatientHttp.configure do |config|
  config.register_payload_store(:redis, adapter: :redis, redis: Redis.new(url: ENV["REDIS_URL"]), ttl: 86_400)
  config.payload_store_threshold = 64 * 1024
end
```

Available adapters:

| Adapter | Options | Notes |
| --- | --- | --- |
| `:file` | `directory:` | Development and testing only; not shared between hosts. |
| `:redis` | `redis:` (required), `ttl:`, `key_prefix:` (default `"patient_http:payloads:"`) | Requires the `redis` gem. The client must respond to `set`, `get`, `del`, and `exists`. |
| `:s3` | `bucket:` (required), `key_prefix:` (default `"patient_http/payloads/"`) | Requires the `aws-sdk-s3` gem. |
| `:active_record` | `model:` (optional) | Requires a migration; see below. |

The ActiveRecord adapter needs a table. Copy this migration into your application:

```ruby
class CreatePatientHttpPayloads < ActiveRecord::Migration[7.0]
  def change
    create_table :patient_http_payloads, id: false do |t|
      t.string :key, null: false, limit: 36
      t.text :data, null: false
      t.timestamps
    end

    add_index :patient_http_payloads, :key, unique: true
    add_index :patient_http_payloads, :created_at
  end
end
```

Write your own adapter by subclassing `PatientHttp::PayloadStore::Base`:

```ruby
class MyStore < PatientHttp::PayloadStore::Base
  register :my_store, self

  def store(key, data)
    # Store the hash and return the key
  end

  def fetch(key)
    # Return the hash or nil if not found
  end

  def delete(key)
    # Delete the data (idempotent)
  end
end

config.register_payload_store(:custom, adapter: :my_store, **options)
```

Multiple stores can be registered when migrating between them. The last one registered is used for new writes; all of them remain available for reads.

To store and fetch payloads yourself, use `PatientHttp::ExternalStorage`:

```ruby
storage = PatientHttp::ExternalStorage.new(PatientHttp.configuration)

data = storage.store(response.as_json, max_size: 1024) # returns the original hash if under 1KB
storage.storage_ref?(data)                             # => true when it was stored
storage.fetch(data)                                    # fetches the original hash
storage.delete(data)                                   # deletes the stored payload
```

## Redirects

Redirect responses (300, 301, 302, 303, 307, and 308) with a `Location` header are followed automatically, up to `max_redirects` hops. A 300 response is followed only when the server names a preferred choice in `Location`. Redirect loops raise `RecursiveRedirectError` and exceeding the limit raises `TooManyRedirectsError`. Any redirect that is not followed is delivered to the callback as a normal response.

The HTTP method of the redirected request follows RFC 9110:

| Status | Method |
| --- | --- |
| 301, 302 | `POST` becomes `GET` and the body is dropped. Other methods (including `HEAD`, `PUT`, `DELETE`, and `QUERY`) are preserved with their body. |
| 303 | `GET` and `HEAD` are preserved. Every other method becomes `GET` and the body is dropped. |
| 300, 307, 308 | The method and body are preserved. |

The QUERY specification states that the POST-to-GET exception on 301 and 302 does not apply to `QUERY`, so a redirected `QUERY` is re-sent as a `QUERY` with its body, and a 303 turns it into a `GET`.

### Preventing method changes

Set `follow_method_changing_redirects: false` to stop following redirects that would change the HTTP method. A `POST` that receives a 302 then completes with the 302 response instead of being retried as a `GET`. Redirects that preserve the method (a `PUT` on a 301, or any method on a 307) are still followed. The option can be set on the configuration or on a single request; the request value wins when both are set.

```ruby
PatientHttp.configure { |config| config.follow_method_changing_redirects = false }

# Or per request
PatientHttp.post(url, callback: MyCallback, body: payload, follow_method_changing_redirects: false)
```

### Stripping headers on redirects

`Authorization` and `Cookie` headers are always removed on cross-origin redirects. To make sure other sensitive headers are never sent to a redirect target, list them in `redirect_strip_headers`. Header names are matched case insensitively. Listed headers are removed from every redirected request, same-origin or not.

```ruby
PatientHttp.configure { |config| config.redirect_strip_headers = ["X-Api-Key", "X-Internal-Token"] }

# Or per request; these are stripped in addition to the configured headers
PatientHttp.get("https://api.example.com/data", callback: FetchCallback, redirect_strip_headers: "X-Signature")
```

Per-request header names survive serialization into the job queue, so they apply no matter which process follows the redirect.

Stripping applies to the headers set on the request. Preprocessors run again on each same-origin redirect and can add headers after the strip, so a header that a preprocessor sets is sent to the redirect target. When a redirect changes the method and drops the body, the headers that describe the body (`Content-Type`, `Content-Length`, `Content-Encoding`, `Content-Language`, and `Content-Location`) are removed as well.

## Response and Error Objects

`PatientHttp::Response` and the error objects are serializable as JSON, which is what makes them safe to pass through job queues and across process boundaries. Both provide `as_json` and `to_json`, and are reconstructed with the `load` class methods:

```ruby
response = PatientHttp::Response.load(json_data)
error = PatientHttp::HttpError.load(json_data)
```

The `Response` object includes the HTTP status code, headers, body, and callback arguments. Error objects (`HttpError`, `RedirectError`, `RequestError`) include the error message, context about the request, and callback arguments.

Request and response headers are case insensitive. A request header with a `nil` or empty string value is never sent: setting a header to `nil` or `""` removes it, and a header hash such as `{"X-Header" => nil}` does not set the header at all. Headers that appear multiple times in the response (such as `set-cookie`) are flattened into a single joined string value.

Response bodies are automatically encoded for JSON serialization. Binary content is Base64 encoded, and large text content is gzipped and then Base64 encoded to reduce payload size. Decoding is handled transparently when you access the `body` or `json` methods on the `Response` object.

## Troubleshooting

### Warning: `ThreadError: Attempt to unlock a mutex which is not locked`

On some Ruby versions you may see a warning like this in your logs:

```
warn: Async::Task: Async::Pool::Controller Gardener [...]
    | Task may have ended with unhandled exception.
    |   ThreadError: Attempt to unlock a mutex which is not locked
    |   → .../async-pool-x.y.z/lib/async/pool/controller.rb:132 in `synchronize'
```

This is caused by [Ruby bug #20907](https://bugs.ruby-lang.org/issues/20907) (see also [socketry/async#424](https://github.com/socketry/async/issues/424)): under the fiber scheduler, a fiber interrupted while waiting on a `ConditionVariable` fails to re-acquire its mutex before unwinding, raising a spurious `ThreadError`. It appears whenever a pooled HTTP client is closed while its connection pool's background "gardener" task is idle — for example when a connection is evicted after a connection error, when the least recently used client is evicted because the pool is full, or when the processor shuts down.

The warning is harmless — connections are still closed correctly; only the log noise is wrong. The fix is to upgrade Ruby: the bug is fixed in Ruby 3.2.7+, 3.3.7+, and 3.4+.

## Building a Custom Integration

Everything below is for integrating PatientHttp with a job system that has no gem yet. If you are using Sidekiq or Solid Queue, their integration gems do all of this for you.

An integration has three parts: a `TaskHandler` that delivers results to your job system, a `Processor` that runs requests, and a registered handler so application code can keep using the `PatientHttp` module methods.

### TaskHandler

The `TaskHandler` is the integration point between the processor and your job system.

```ruby
class MyTaskHandler < PatientHttp::TaskHandler
  def initialize(job_id)
    @job_id = job_id
  end

  def on_complete(response, callback)
    MyJobSystem.enqueue(callback, :on_complete, response.as_json)
  end

  def on_error(error, callback)
    MyJobSystem.enqueue(callback, :on_error, error.as_json)
  end

  def retry
    # Re-enqueue the original job when the processor shuts down
    # with this request still in flight
    MyJobSystem.enqueue_job(@job_id)
  end
end
```

> **Important:** TaskHandler callbacks run on the processor's completion worker threads (see `completion_threads`), not the reactor thread, so they do not block the event loop. Keep them lightweight anyway — typically just enqueuing a message for another system to pick up. Heavy callbacks compete with the reactor for the GVL, and because a task stays in the capacity count until its result is delivered, callbacks that back up consume request capacity.
>
> Callbacks must be thread-safe. Results are delivered concurrently on `completion_threads` workers (default 2), so two callbacks can run at the same time and in an order unrelated to the order the requests completed. Set `completion_threads: 1` to serialize delivery.
>
> Callbacks must also be idempotent. A callback that raises is retried `completion_retries` times (default 2), so one that raises after enqueuing its message enqueues it again. Set `completion_retries: 0` if that is not acceptable.

Encryption is the handler's responsibility. The base class does not call encrypt or decrypt; use `Configuration#encryptor` at every serialization boundary:

```ruby
def on_complete(response, callback)
  encrypted = @configuration.encryptor.encrypt(response.as_json)
  MyJobSystem.enqueue(callback, :on_complete, encrypted)
end
```

And decrypt before rebuilding the object:

```ruby
response = PatientHttp::Response.load(@configuration.encryptor.decrypt(data))
```

### Running a processor

```ruby
config = PatientHttp::Configuration.new(max_connections: 256, request_timeout: 60)
processor = PatientHttp::Processor.new(config)
processor.start

task = PatientHttp::RequestTask.new(
  request: PatientHttp::Request.new(:get, "https://api.example.com/users/123"),
  task_handler: MyTaskHandler.new("job-123"),
  callback: "FetchUserCallback",
  callback_args: {user_id: 123}
)
processor.enqueue(task)
```

A process can run several named processors, each with its own capacity and threads:

```ruby
PatientHttp::Processor.new(config, name: :llm)
```

Requests carry an optional `processor` name that is serialized with the request, which is what integrations route on.

### Processor lifecycle

```
stopped -> starting -> running -> draining -> stopping -> stopped
```

- **stopped**: Not processing requests
- **starting**: Initializing the reactor thread
- **running**: Accepting and processing requests
- **draining**: Rejecting new requests, completing in-flight ones
- **stopping**: Shutting down, re-enqueuing incomplete requests

```ruby
processor.start              # Start processing
processor.running?           # => true

processor.drain              # Stop accepting new requests
processor.draining?          # => true

processor.stop(timeout: 25)  # Graceful shutdown
processor.stopped?           # => true
```

When the processor stops with in-flight requests, it calls `TaskHandler#retry` on each incomplete task so they can be re-enqueued.

### Observing the processor

```ruby
class MetricsObserver < PatientHttp::ProcessorObserver
  def request_start(request_task)
    StatsD.increment("http_pool.request.start")
  end

  def request_end(request_task)
    StatsD.timing("http_pool.request.duration", request_task.duration * 1000)
  end

  def request_error(error)
    StatsD.increment("http_pool.request.error")
  end

  def capacity_exceeded
    StatsD.increment("http_pool.capacity_exceeded")
  end
end

processor.observe(MetricsObserver.new)
```

Observers can also track the full task pipeline:

- `request_enqueued(request_task)` is called when a task is announced to the processor, before it is visible to the reactor. It is guaranteed to arrive before `request_start`, so observers can set up durable tracking (such as a crash-recovery registry entry) before `Processor#enqueue` returns or raises.
- `request_rejected(request_task)` is called when an announced task is not accepted (not running or at capacity), so observers can tear down anything they set up in `request_enqueued`.
- `request_requeued(request_task)` is called when an incomplete task is re-enqueued through its task handler (processor shutdown or reactor failure). The job system owns the request again once this is sent.
- `completion_failed(request_task, error)` is called when a result could not be delivered after all retries. `request_end` is not sent in that case, so durable tracking survives for external recovery.

Use `Processor#tracked_request_ids` to get the IDs of all tasks in the pipeline (queued, pending, and in-flight), for example to keep heartbeats alive for tasks that have not started yet.

### Registering a handler

Register a handler so application code can use the `PatientHttp` module methods instead of building tasks by hand:

```ruby
PatientHttp.register_handler do |request:, callback:, callback_args: nil, raise_error_responses: nil|
  task = PatientHttp::RequestTask.new(
    request: request,
    task_handler: MyTaskHandler.new,
    callback: callback,
    callback_args: callback_args,
    raise_error_responses: raise_error_responses
  )
  processor.enqueue(task)
end
```

Use `PatientHttp.register_handler!` to raise if one is already registered, and `PatientHttp.handler_registered?` to check.

To make `PatientHttp.configure` yield your own configuration class, register the integration as the configuration provider. It must respond to `new_configuration`, returning a new configuration instance, and to `configure`:

```ruby
PatientHttp.register_configuration_provider(MyIntegration)
```

### Testing an integration

`SynchronousExecutor` runs a request synchronously, so integration logic can be tested without starting the async processor:

```ruby
executor = PatientHttp::SynchronousExecutor.new(
  task,
  config: config,
  on_complete: ->(response) { StatsD.increment("complete") },
  on_error: ->(error) { StatsD.increment("error") }
)

executor.call
```

## Installation

Most applications should install the integration for their job system, which depends on this gem:

```ruby
gem "patient_http-sidekiq"
# or
gem "patient_http-solid_queue"
```

To use this gem on its own, add:

```ruby
gem "patient_http"
```

Then execute:

```bash
bundle install
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http).

Please use the [standardrb](https://github.com/testdouble/standard) syntax and lint your code with `standardrb --fix` before submitting.

The [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) and [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gems each provide a test application for integration testing.

## Further Reading

- [Architecture](ARCHITECTURE.md)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
