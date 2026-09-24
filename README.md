# PatientHttp

[![Continuous Integration](https://github.com/bdurand/patient_http/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http.svg)](https://badge.fury.io/rb/patient_http)

*Built for APIs that like to think.*

PatientHttp is an asynchronous HTTP connection pool for Ruby applications. It uses fiber-based concurrency.

## Motivation

In a threaded application, a thread that makes an HTTP request blocks while it waits for I/O. One slow API response ties up the whole thread. When many threads wait on HTTP I/O at the same time, throughput collapses.

PatientHttp runs HTTP requests in a dedicated processor thread that uses Ruby's fiber scheduler for non-blocking I/O. Application threads hand off HTTP requests to the processor and return immediately. The processor handles hundreds of concurrent HTTP connections with fibers. When responses arrive, it notifies the application through a callback mechanism that you can replace.

Application threads stay free to do other work while HTTP requests are in flight.

Most applications use this gem through an integration, such as [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) or [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue). These gems provide a request handler for their job processing system. You enqueue HTTP requests from your application code, and your code doesn't depend on the processor implementation. For details, see [Integration](#integration).

The [patient_llm](https://github.com/bdurand/patient_llm) gem provides an integration for asynchronous large language model (LLM) requests. LLM requests were the original reason for PatientHttp, because they can take much longer than typical HTTP requests.

## Quick start

To get started, implement a task handler, enqueue requests, and handle the callbacks.

### Implement a task handler

A `TaskHandler` connects the pool to your application. It defines what happens when a request completes, fails, or needs to be retried.

```ruby
class MyTaskHandler < PatientHttp::TaskHandler
  def initialize(job_id)
    @job_id = job_id
  end

  def on_complete(response, callback)
    # Enqueue a message for your application to process the response.
    # This method runs on a completion worker thread, concurrently with other
    # completions, so keep it lightweight and thread-safe.
    MyJobSystem.enqueue(callback, :on_complete, response.as_json)
  end

  def on_error(error, callback)
    MyJobSystem.enqueue(callback, :on_error, error.as_json)
  end

  def retry
    # Re-enqueue the original job when the processor shuts down with
    # in-flight requests.
    MyJobSystem.enqueue_job(@job_id)
  end
end
```

> **Important:** `TaskHandler` callbacks run on the processor's completion worker threads (see `completion_threads`), not on the reactor thread, so they don't block the event loop. Keep them lightweight anyway. Usually, a callback only enqueues a message for another system to pick up. Heavy callbacks compete with the reactor for the global VM lock (GVL). A task counts toward capacity until its result is delivered, so callbacks that fall behind use up request capacity.
>
> Callbacks must be thread-safe. Results are delivered concurrently on the `completion_threads` workers (default 2). Two callbacks can run at the same time, in any order, regardless of the order in which the requests completed. To deliver results one at a time, set `completion_threads: 1`.
>
> Callbacks must also be idempotent. If a callback raises an error, it's retried `completion_retries` times (default 2). A callback that raises an error after it enqueues its message enqueues the message again. If that isn't acceptable, set `completion_retries: 0`.

### Create and enqueue requests

```ruby
# Configure the processor.
config = PatientHttp::Configuration.new(
  max_connections: 256,
  request_timeout: 60
)

# Start the processor.
processor = PatientHttp::Processor.new(config)
processor.start

# Build a request.
request = PatientHttp::Request.new(
  :get,
  "https://api.example.com/users/123",
  headers: {"Authorization" => "Bearer token"}
)

# Create a task with your handler.
task = PatientHttp::RequestTask.new(
  request: request,
  task_handler: MyTaskHandler.new("job-123"),
  callback: "FetchDataCallback",
  callback_args: {user_id: 123}
)

# Enqueue the task.
processor.enqueue(task)
```

### Handle callbacks

When the HTTP request completes, the processor calls `TaskHandler#on_complete` with the `Response` and the callback class name. Your handler invokes the callback in the way that fits your application, such as by enqueuing a background job.

```ruby
class FetchDataCallback
  def on_complete(response)
    user_id = response.callback_args[:user_id]
    data = response.json
    User.find(user_id).update!(external_data: data)
  end

  def on_error(error)
    user_id = error.callback_args[:user_id]
    Rails.logger.error("Failed for user #{user_id}: #{error.message}")
  end
end
```

## HTTP error responses

By default, requests with HTTP error status codes (4xx and 5xx) are treated as completed. To check the status, use the helper methods on the response:

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

To treat non-2xx responses as errors instead, set `raise_error_responses: true` on the `RequestTask`:

```ruby
task = PatientHttp::RequestTask.new(
  request: request,
  task_handler: handler,
  callback: "ApiCallback",
  raise_error_responses: true
)
```

With this option set, a non-2xx response calls `TaskHandler#on_error` with an `HttpError`. The error gives you access to the response:

```ruby
def on_error(error)
  if error.is_a?(PatientHttp::HttpError)
    puts error.status           # HTTP status code
    puts error.url              # Request URL
    puts error.response.body    # Response body
  end
end
```

## Request templates

To share configuration across requests to the same API, use `RequestTemplate`:

```ruby
template = PatientHttp::RequestTemplate.new(
  base_url: "https://api.example.com",
  headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
  timeout: 60
)

# Build requests from the template.
get_request = template.get("/users/123")
post_request = template.post("/users", json: {name: "John"})
```

Templates support all HTTP methods: `get`, `head`, `post`, `put`, `patch`, `delete`, and `query`. They join URLs, merge headers, and encode query parameters.

## Standard interface

The `PatientHttp` module provides a standard interface for building and dispatching requests. You don't need to interact with the processor or task handlers directly. Your application code makes HTTP requests without depending on the asynchronous processing infrastructure.

First, register a request handler with `PatientHttp.register_handler`. The handler defines how requests are dispatched to your job queue or background processing system. Then use the `PatientHttp` class methods or the `RequestHelper` mixin to make asynchronous HTTP requests with callbacks.

```ruby
# The handler receives keyword arguments for the request, callback, and any additional callback arguments.
PatientHttp.register_handler do |request:, callback:, callback_args: nil, raise_error_responses: nil|
  # Example integration point. Adapt this code to your application.
  # Build a RequestTask and enqueue it to your processor.
  task = PatientHttp::RequestTask.new(
    request: request,
    task_handler: MyTaskHandler.new,
    callback: callback,
    callback_args: callback_args,
    raise_error_responses: raise_error_responses
  )

  processor.enqueue(task)
end

# Make requests through the PatientHttp interface with the .request, .get, .head,
# .post, .patch, .put, .delete, and .query class methods.
PatientHttp.get(
  "https://api.example.com/users/123",
  callback: FetchUserCallback,
  callback_args: {user_id: 123}
)
```

The [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) and [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gems register the handler for you.

### Inline execution

In consoles, tests, and development environments without a job system, you can register a handler that executes requests inline. Inline requests run synchronously in the current process instead of being dispatched to a queue:

```ruby
PatientHttp.inline!
```

After you call `inline!`, every request made through the `PatientHttp` interface or the `RequestHelper` mixin runs immediately. The request goes through the full request lifecycle, including timeouts, redirects, and error wrapping. The callback runs on the calling thread before the method returns. Callbacks can make more requests, and those requests also run inline.

```ruby
PatientHttp.inline!
PatientHttp.get("https://api.example.com/users/123", callback: FetchUserCallback)
# FetchUserCallback#on_complete has already run at this point.
```

By default, inline requests use `PatientHttp.default_configuration`. If no default configuration is set, PatientHttp creates one on first use that includes any secrets registered with `PatientHttp.register_secret`. For more information, see [Secrets](#secrets). You can also pass a configuration:

```ruby
PatientHttp.inline!(config: PatientHttp::Configuration.new(raise_error_responses: true))
```

To check whether the inline handler is the registered handler, use `PatientHttp.inline?`. To execute a single request inline without registering a handler, use `PatientHttp.execute_inline(request:, callback:)`.

### RequestHelper mixin

Use `PatientHttp::RequestHelper` for a compact API that creates and dispatches asynchronous HTTP requests from your class.

1. Register a request handler with `PatientHttp.register_handler`. The handler defines how requests are dispatched to your job queue or background processing system.
2. Include `PatientHttp::RequestHelper` in your class.
3. Optional: Define a `request_template` for a shared `base_url`, headers, and timeout.
4. Call `async_get`, `async_head`, `async_post`, `async_put`, `async_patch`, `async_delete`, `async_query`, or `async_request`.

```ruby
class ApiClient
  include PatientHttp::RequestHelper

  request_template(
    base_url: "https://api.example.com",
    headers: {"Authorization" => "Bearer #{ENV["API_KEY"]}"},
    timeout: 60
  )

  def fetch_user(user_id)
    async_get(
      "/users/#{user_id}",
      callback: FetchUserCallback,
      callback_args: {user_id: user_id}
    )
  end

  def update_user(user_id, data)
    async_patch(
      "/users/#{user_id}",
      json: data,
      callback: UpdateUserCallback,
      callback_args: {user_id: user_id}
    )
  end
end
```

## Callback arguments

To pass your own data from the request to the callback, use `callback_args`:

```ruby
task = PatientHttp::RequestTask.new(
  request: request,
  task_handler: handler,
  callback: "FetchDataCallback",
  callback_args: {user_id: 123, request_timestamp: Time.now.iso8601}
)
```

Callback arguments are available on both `Response` and `Error` objects:

```ruby
response.callback_args[:user_id]    # Symbol access
response.callback_args["user_id"]   # String access
```

Callback arguments must contain only JSON-native types: `nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, and `Hash`. Hash keys are converted to strings for serialization.

## Response and error objects

`PatientHttp::Response` and the error objects serialize to JSON and deserialize from it, so you can pass them through job queues and across process boundaries. Your `TaskHandler` callbacks can enqueue the response or error data and process it asynchronously somewhere else.

Response and error objects provide `as_json` and `to_json` methods for serialization:

```ruby
def on_complete(response, callback)
  # Serialize the response for background processing.
  MyJobSystem.enqueue(callback, :on_complete, response.as_json)
end

def on_error(error, callback)
  # Serialize the error for background processing.
  MyJobSystem.enqueue(callback, :on_error, error.as_json)
end
```

To deserialize the objects, use the `load` class methods:

```ruby
response = PatientHttp::Response.load(json_data)
error = PatientHttp::HttpError.load(json_data)
```

The `Response` object includes the HTTP status code, headers, body, and callback arguments. Error objects (`HttpError`, `RedirectError`, and `RequestError`) include the error message, details about the request, and callback arguments.

Request and response headers are case insensitive. A request header with a `nil` or empty string value is never sent. Setting a header to `nil` or `""` removes it, and a header hash such as `{"X-Header" => nil}` doesn't set the header. If a header appears more than once in the response, such as `set-cookie`, its values are joined into a single string.

Response bodies are encoded for JSON serialization. Binary content is Base64 encoded. Large text content is compressed with gzip and then Base64 encoded to reduce the payload size. When you call the `body` or `json` method on the `Response` object, the body is decoded for you.

### Payload stores

To keep serialized JSON payloads small, you can configure external storage for large request and response payloads. Payloads that exceed the size threshold are stored externally and fetched when they're needed.

If you use a job queue or background processing system, external storage lets you handle large requests and responses without hitting the size or memory limits on queue messages. Your application code doesn't need to know whether a payload is stored externally.

```ruby
# Register a payload store. Use the file adapter only for development and testing.
config.register_payload_store(:my_store, adapter: :file, directory: "/tmp/payloads")

# In your callbacks, use the ExternalStorage class to store and fetch payloads.
storage = PatientHttp::ExternalStorage.new(config)

large_response_data = storage.store(large_response.as_json)
# Returns a reference like {"$ref" => {"store" => "my_store", "key" => "abc123"}}.

small_response_data = storage.store(small_response.as_json, max_size: 1024)
# If the JSON payload is under 1 KB, the payload isn't stored and the original hash is returned.

storage.storage_ref?(large_response_data) # => true
storage.storage_ref?(small_response_data) # => false

storage.fetch(large_response_data) # Fetches the original data from the store.
storage.fetch(small_response_data) # Raises an error because this isn't a reference.

storage.delete(large_response_data) # Deletes the stored payload.
```

#### File store

Use the file store for development and testing:

```ruby
config.register_payload_store(:files, adapter: :file, directory: "/tmp/payloads")
```

#### Redis store

Use the Redis store in production when processes share state. The Redis store requires the `redis` gem. The client must respond to `set`, `get`, `del`, and `exists`.

```ruby
redis = Redis.new(url: ENV["REDIS_URL"])
config.register_payload_store(:redis, adapter: :redis, redis: redis, ttl: 86400)
```

The Redis store accepts the following options:

- `redis:`: The Redis client. Required.
- `ttl:`: The time to live for stored payloads, in seconds. Optional.
- `key_prefix:`: The prefix for Redis keys. Defaults to `"patient_http:payloads:"`.

#### S3 store

Use the S3 store for durable storage that multiple instances share. The S3 store requires the `aws-sdk-s3` gem.

```ruby
s3 = Aws::S3::Resource.new
bucket = s3.bucket("my-payloads-bucket")
config.register_payload_store(:s3, adapter: :s3, bucket: bucket)
```

The S3 store accepts the following options:

- `bucket:`: The S3 bucket. Required.
- `key_prefix:`: The prefix for object keys. Defaults to `"patient_http/payloads/"`.

#### ActiveRecord store

Use the ActiveRecord store for database-backed storage with transactional guarantees:

```ruby
config.register_payload_store(:database, adapter: :active_record)
```

This store requires a database migration. Copy the migration from the gem:

```ruby
# db/migrate/XXXXXX_create_patient_http_payloads.rb
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

The ActiveRecord store accepts an optional `model:` option. It defaults to the built-in `PatientHttp::PayloadStore::ActiveRecordStore::Payload` model.

#### Custom stores

To implement your own store, subclass `PatientHttp::PayloadStore::Base` and implement `store_json`, `fetch`, and `delete`:

```ruby
class MyStore < PatientHttp::PayloadStore::Base
  register :my_store, self

  def store_json(key, json)
    # Store the JSON string and return the key.
  end

  def fetch(key)
    # Return the parsed hash, or nil if the key isn't found.
  end

  def delete(key)
    # Delete the data. This method must be idempotent.
  end
end

config.register_payload_store(:custom, adapter: :my_store, **options)
```

To migrate between stores, register more than one. The last registered store is used for new writes. All registered stores stay available for reads.

## Encryption

When you use PatientHttp with a job queue system, request and response data is serialized into the queue, such as Redis or a database. If this data contains sensitive information, encrypt it.

PatientHttp provides encryption helpers through the `Configuration` object. The `TaskHandler` implementation is responsible for encrypting the serialized data. If you use an integration gem, such as [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) or [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue), its `TaskHandler` handles encryption for you. You only need to configure the encryption key or callables on the `Configuration` object.

If you write a custom `TaskHandler`, get the helper from `Configuration#encryptor`. Call `encrypt` and `decrypt` wherever your handler serializes or deserializes data.

### Use an encryption key

The simplest option is `encryption_key=`. It sets up [ActiveSupport::MessageEncryptor](https://api.rubyonrails.org/classes/ActiveSupport/MessageEncryptor.html) with AES-256-GCM:

```ruby
config = PatientHttp::Configuration.new
config.encryption_key = ENV["PATIENT_HTTP_ENCRYPTION_KEY"]
```

To rotate keys, pass an array. The first key encrypts new data, and all keys are tried for decryption:

```ruby
config.encryption_key = [ENV["PATIENT_HTTP_ENCRYPTION_KEY"], ENV["PATIENT_HTTP_OLD_KEY"]]
```

### Use custom callables

To use another encryption library, provide callables that accept and return raw bytes as a `String`:

```ruby
config.encryption { |bytes| MyEncryption.encrypt(bytes) }
config.decryption { |bytes| MyEncryption.decrypt(bytes) }
```

You can also pass any object that responds to `#call`:

```ruby
config.encryption(->(bytes) { MyEncryption.encrypt(bytes) })
config.decryption(->(bytes) { MyEncryption.decrypt(bytes) })
```

### Add encryption to a custom task handler

If you write your own `TaskHandler` instead of using one from an integration gem, you must add encryption yourself. `Configuration#encryptor` returns an `Encryptor` built from the configured callables. Call it at every serialization boundary:

```ruby
class MyTaskHandler < PatientHttp::TaskHandler
  def initialize(job_id, configuration:)
    @job_id = job_id
    @configuration = configuration
  end

  def on_complete(response, callback)
    # Encrypt the serialized response before you enqueue it.
    encrypted = @configuration.encryptor.encrypt(response.as_json)
    MyJobSystem.enqueue(callback, :on_complete, encrypted)
  end

  def on_error(error, callback)
    encrypted = @configuration.encryptor.encrypt(error.as_json)
    MyJobSystem.enqueue(callback, :on_error, encrypted)
  end

  def retry
    MyJobSystem.enqueue_job(@job_id)
  end
end

# Keep a reference to the configuration and use config.encryptor where you need it.
handler = MyTaskHandler.new("job-123", configuration: config)
```

In your callback, decrypt the data before you process it:

```ruby
class FetchDataCallback
  def initialize(configuration:)
    @configuration = configuration
  end

  def on_complete(data)
    response = PatientHttp::Response.load(@configuration.encryptor.decrypt(data))
    # ...
  end
end
```

### How encryption works

Encrypted data is stored as `{"__encrypted__" => true, "value" => "<base64>"}`. The `Encryptor` serializes the original hash to JSON, passes the bytes to your callable, and Base64 encodes the result. Decryption reverses the process. Hashes without the `"__encrypted__"` key pass through unchanged, so existing unencrypted data keeps working while you roll out encryption.

## Secrets

Requests are serialized into your job queue before they run. If you put a sensitive value directly on the request, such as an API token in an `Authorization` header or an API key in a query parameter, that value is written to the queue. You can encrypt requests in the queue, but it's better to keep sensitive values off the request entirely.

The secret manager lets you reference sensitive values in headers or query parameters by name. The serialized request stores only a reference marker, `{"$secret" => "name"}`, and never the value. The value lives on the `Configuration` on the processor side, and it's resolved when the request is sent.

### Define secrets

Register named secrets on the `Configuration`. You can provide the value directly or as a block. A block runs each time the secret is resolved, which is useful for reading from the environment when the value is needed:

```ruby
config = PatientHttp::Configuration.new
config.register_secret(:authorization, "Bearer #{ENV['API_TOKEN']}") # static value
config.register_secret(:api_key) { ENV["MY_API_KEY"] } # block that runs on each use
```

If a secret isn't found when a request is resolved, PatientHttp raises a `PatientHttp::SecretManager::SecretNotFoundError`. The error goes through the normal request error path.

#### Module-level registration

If an integration gem, such as patient_http-sidekiq or patient_http-solid_queue, owns the `Configuration`, your application code might not have a reference to it. Your code might also load before the configuration exists. In that case, register secrets at the module level:

```ruby
PatientHttp.register_secret(:authorization, "Bearer #{ENV['API_TOKEN']}")
PatientHttp.register_secret(:api_key) { ENV["MY_API_KEY"] }
```

Module-level secrets are applied to `PatientHttp.default_configuration`. If a default configuration is already set, the secrets are applied immediately. Otherwise, they're applied when a default configuration is set. The order in which your application code and the integration gem load doesn't matter. Integration gems set the default configuration at the end of their configuration step. You can also set it yourself:

```ruby
PatientHttp.default_configuration = config
```

To check whether a secret is available at the module level or on the default configuration, use `PatientHttp.secret_registered?(name)`.

### Reference secrets in a request

Use `PatientHttp.secret(name)` anywhere you would put a sensitive header or query parameter value. The value isn't needed, or available, when you build the request:

```ruby
PatientHttp.get(
  "https://api.example.com/data",
  callback: MyCallback,
  headers: {"Authorization" => PatientHttp.secret(:api_token)},
  params: {"api_key" => PatientHttp.secret(:api_key), "page" => 2}
)
```

The request serializes the secret header as `{"$secret" => "api_token"}` and keeps the secret query parameter out of the URL. Other parameters, such as `page`, are added to the URL as usual. The processor resolves both secrets right before it sends the request. It sets the header to the resolved value and appends the resolved query parameter to the URL.

## Request preprocessors

A preprocessor changes a request right before it's sent. The most common use is signing requests. Signing schemes like AWS Signature Version 4 (SigV4) compute values over the final outgoing request, including the method, URL, headers, and body, and set several headers. A static header value set when you build the request can't do that.

Like secrets, preprocessors are registered on the `Configuration`, and requests reference them by name. The serialized request contains only the name. The signing logic and its credentials stay on the processor side and are never written to the job queue.

### Define preprocessors

Register a named preprocessor as a block or a callable that takes one argument:

```ruby
config = PatientHttp::Configuration.new
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
```

The argument is a `PatientHttp::OutgoingRequest`, which shows the request as it's about to be sent. At this point, all secret references are resolved, and the `x-request-id` and default `User-Agent` headers are set. The object provides the following:

- `http_method`, `url`, and `body`: Read-only values. The URL includes any resolved secret query parameters.
- `headers`: Mutable, case-insensitive headers.
- `add_param(name, value)`: Appends a query parameter to the URL, for signing schemes that use query parameters.

### Attach preprocessors to a request

When you build a request, reference registered preprocessors by name:

```ruby
PatientHttp.post(
  "https://api.example.com/data",
  callback: MyCallback,
  json: {value: 1},
  preprocessors: :aws_sigv4
)
```

To use more than one preprocessor, pass an array. Preprocessors run in order, and each one sees the changes made by the ones before it. `RequestTemplate` and the `RequestHelper` mixin's `request_template` also accept `preprocessors:` as a default for all requests. The mixin's `async_*` helpers accept `preprocessors:` for each request.

If a request references a preprocessor name that isn't registered, PatientHttp raises a `PatientHttp::RequestPreparer::PreprocessorNotFoundError`. The error goes through the normal request error path.

When a redirect is followed, preprocessors run again for each redirect URL, so signatures stay valid. On cross-origin redirects, preprocessors are dropped, in the same way that the `Authorization` and `Cookie` headers are stripped. Signed credentials are never sent to an unexpected origin.

## Redirects

PatientHttp follows redirect responses (300, 301, 302, 303, 307, and 308) that have a `Location` header, up to `max_redirects` hops. A 300 response is followed only when the server names a preferred choice in `Location`. A redirect loop raises `RecursiveRedirectError`, and exceeding the limit raises `TooManyRedirectsError`. A redirect that isn't followed is delivered to the callback as a normal response.

The HTTP method of the redirected request follows RFC 9110:

| Status | Method |
| --- | --- |
| 301, 302 | `POST` becomes `GET`, and the body is dropped. Other methods, including `HEAD`, `PUT`, `DELETE`, and `QUERY`, are preserved with their body. |
| 303 | `GET` and `HEAD` are preserved. Every other method becomes `GET`, and the body is dropped. |
| 300, 307, 308 | The method and body are preserved. |

The QUERY specification states that the `POST`-to-`GET` exception on 301 and 302 doesn't apply to `QUERY`. A redirected `QUERY` is re-sent as a `QUERY` with its body, and a 303 turns it into a `GET`.

### Prevent method changes

To stop following redirects that would change the HTTP method, set `follow_method_changing_redirects: false`. For example, a `POST` that receives a 302 then completes with the 302 response instead of being retried as a `GET`. Redirects that preserve the method, such as a `PUT` on a 301 or any method on a 307, are still followed. You can set the option on the `Configuration` or on a single `Request`. If both are set, the request value takes precedence.

```ruby
config = PatientHttp::Configuration.new(follow_method_changing_redirects: false)

# Or set the option for a single request.
request = PatientHttp::Request.new(:post, "https://api.example.com/submit", body: payload, follow_method_changing_redirects: false)
```

### Strip headers on redirects

`Authorization` and `Cookie` headers are always removed on cross-origin redirects. To make sure other sensitive headers are never sent to a redirect target, list them in `redirect_strip_headers`. Header names are case insensitive. Listed headers are removed from every redirected request, whether or not the redirect is cross-origin.

```ruby
config = PatientHttp::Configuration.new(redirect_strip_headers: ["X-Api-Key", "X-Internal-Token"])

# Or set the option for a single request. These headers are stripped in addition to the configured headers.
request = PatientHttp::Request.new(:get, "https://api.example.com/data", headers: headers, redirect_strip_headers: "X-Signature")

# PatientHttp.request, the async_* helpers, and RequestTemplate accept the same option.
PatientHttp.get("https://api.example.com/data", callback: FetchCallback, redirect_strip_headers: "X-Signature")
```

Header names set on a request are serialized with it into the job queue, so they apply in any process that follows the redirect.

Stripping applies to the headers set on the request. Preprocessors run again on each same-origin redirect and can add headers after stripping, so a header that a preprocessor sets is sent to the redirect target. When a redirect changes the method and drops the body, the headers that describe the body are also removed: `Content-Type`, `Content-Length`, `Content-Encoding`, `Content-Language`, and `Content-Location`.

## Troubleshooting

### Warning: `ThreadError: Attempt to unlock a mutex which is not locked`

On some Ruby versions, you might see a warning like this in your logs:

```
warn: Async::Task: Async::Pool::Controller Gardener [...]
    | Task may have ended with unhandled exception.
    |   ThreadError: Attempt to unlock a mutex which is not locked
    |   → .../async-pool-x.y.z/lib/async/pool/controller.rb:132 in `synchronize'
```

[Ruby bug #20907](https://bugs.ruby-lang.org/issues/20907) causes this warning. For more information, see [socketry/async#424](https://github.com/socketry/async/issues/424). Under the fiber scheduler, a fiber that is interrupted while it waits on a `ConditionVariable` fails to reacquire its mutex before it unwinds, and raises a spurious `ThreadError`. The warning appears when a pooled HTTP client closes while the background "gardener" task of its connection pool is idle. For example, this happens when a connection is evicted after a connection error, when the least recently used client is evicted because the pool is full, or when the processor shuts down.

The warning is harmless. Connections still close correctly, and only the log message is wrong. To fix it, upgrade Ruby. The bug is fixed in Ruby 3.2.7 and later, 3.3.7 and later, and 3.4 and later.

## Configuration

```ruby
config = PatientHttp::Configuration.new(
  # Maximum number of concurrent HTTP requests (default: 256).
  max_connections: 256,

  # Default timeout for HTTP requests, in seconds (default: 60).
  request_timeout: 60,

  # Timeout for graceful shutdown, in seconds (default: 30).
  shutdown_timeout: 30,

  # Maximum response body size, in bytes (default: 1 MB).
  max_response_size: 1024 * 1024,

  # Default User-Agent header (default: "PatientHttp").
  user_agent: "MyApp/1.0",

  # Whether non-2xx responses are treated as errors by default (default: false).
  raise_error_responses: false,

  # Maximum number of redirects to follow. 0 disables redirects (default: 5).
  max_redirects: 5,

  # Whether to follow redirects that must change the HTTP method, such as POST
  # to GET on a 302 (default: true). If false, those requests receive the
  # redirect response.
  follow_method_changing_redirects: true,

  # Header names that are always stripped from redirected requests. Names are
  # case insensitive (default: []). Authorization and Cookie are always
  # stripped on cross-origin redirects.
  redirect_strip_headers: ["X-Api-Key", "X-Internal-Token"],

  # Maximum number of hosts to keep persistent connections for (default: 100).
  connection_pool_size: 100,

  # Time limit for establishing a connection, in seconds. The limit covers the
  # TCP connect and the TLS handshake (default: nil, no separate limit).
  # request_timeout alone limits the wait for the response.
  connection_timeout: 10,

  # HTTP or HTTPS proxy URL (default: nil).
  proxy_url: "http://proxy.example.com:8080",

  # TCP keepalive for pooled connections (default: nil, which keeps the kernel
  # defaults). An integer sets the idle seconds before the first probe. A hash
  # can also set :interval (seconds between probes, default 10) and :count
  # (probes before the peer is declared dead, default 3). Probes keep NAT and
  # firewall mappings alive while a connection is idle, and they detect a dead
  # peer before the connection is reused.
  tcp_keepalive: 30,

  # Number of seconds that transmitted data can stay unacknowledged before the
  # kernel aborts the connection (default: nil, which keeps the kernel default;
  # Linux only). A request sent to a peer that has gone away fails after this
  # time instead of after request_timeout. Data that the peer has acknowledged
  # isn't affected, so a server that takes minutes to respond isn't cut short.
  tcp_user_timeout: 30,

  # Maximum number of attempts for a request that fails before any response
  # bytes arrive (default: 3). At least 3 attempts are always allowed. A
  # failure is retried immediately when a retry is known to be safe: the server
  # refused the request before processing it, such as with an HTTP/2 GOAWAY,
  # or the method is idempotent (GET, HEAD, PUT, DELETE, or QUERY) and the
  # connection failed. Connection failures include EOF, a reset, a broken pipe,
  # and the kernel giving up on unacknowledged data. A connection failure is
  # retried on a new connection. A POST or PATCH whose connection failed with
  # an unknown outcome isn't retried, and neither is a request that reached
  # request_timeout.
  retries: 3,

  # Force the HTTP protocol to :http1 or :http2 (default: nil, which negotiates
  # with the server and prefers HTTP/2 for HTTPS). Forcing :http1 also limits
  # the TLS ALPN advertisement to http/1.1, which works around SSL-intercepting
  # proxies that mishandle HTTP/2.
  protocol: nil,

  # Logger (default: a Logger that writes to standard error at the ERROR level).
  logger: Logger.new($stdout)
)

# Register named secrets to reference sensitive headers and parameters
# indirectly. For more information, see Secrets.
config.register_secret(:api_token, ENV["MY_API_TOKEN"])
```

### Tuning tips

- `max_connections`: Each connection uses memory and file descriptors. A tuned system can handle thousands.
- `max_connections_per_host`: Limits the sockets for each host (default: no limit). For high-concurrency deployments, set a value such as 32 so that one host can't use every file descriptor. Make sure the process file descriptor limit covers `max_connections`, plus idle pooled host connections, plus the application's own connections.
- `request_timeout`: Set this value based on expected API response times. AI and LLM APIs might need minutes.
- `connection_pool_size`: Increase this value for applications that call many different API hosts.
- `max_response_size`: Keeps memory use bounded. Large responses might need external payload storage. For compressed responses, the limit applies to the inflated bytes.
- Response compression: By default, requests ask for `gzip`, and the body is inflated on a completion worker thread. To change this behavior, set `accept-encoding` on a request. `identity` turns off compression. Any other encoding is delivered still encoded, with its `content-encoding` header, so you can decode it yourself.
- `completion_threads`: The number of threads that decode responses and deliver results (default: 2). Increase this value when callbacks do heavier work, such as serialization or encryption, and completions back up behind them. Any value above 1 delivers results concurrently, so `TaskHandler` callbacks and completion-time observers must be thread-safe. To deliver results one at a time, use 1.
- `completion_retries`: The number of delivery retries before a result is reported through `completion_failed` (default: 2). A retry calls `on_complete` or `on_error` again, so a handler that raises an error after it enqueues its message delivers that message twice. Make handlers idempotent, or set `completion_retries: 0` to report the first failure without retrying.
- `shutdown_timeout`: Set this value below the termination window of your process supervisor, so the drain, including handed-off completions, finishes before a forced stop.

## Processor lifecycle

The processor moves through the following states:

```
stopped -> starting -> running -> draining -> stopping -> stopped
```

- `stopped`: Not processing requests.
- `starting`: Starting the reactor thread.
- `running`: Accepting and processing requests.
- `draining`: Rejecting new requests and completing in-flight requests.
- `stopping`: Shutting down and re-enqueuing incomplete requests.

```ruby
processor = PatientHttp::Processor.new(config)

processor.start              # Start processing.
processor.running?           # => true

processor.drain              # Stop accepting new requests.
processor.draining?          # => true

processor.stop(timeout: 25)  # Shut down gracefully.
processor.stopped?           # => true
```

When the processor stops with in-flight requests, it calls `TaskHandler#retry` on each incomplete task so the task can be re-enqueued.

### Observe the processor

To monitor processor events, register observers:

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

- `request_enqueued(request_task)` is called when a task is handed to the processor, before the reactor can see it. It always arrives before `request_start`. Observers can set up durable tracking, such as a crash recovery registry entry, before `Processor#enqueue` returns or raises an error.
- `request_rejected(request_task)` is called when the processor doesn't accept an announced task, because it isn't running or is at capacity. Observers can remove anything they set up in `request_enqueued`.
- `request_requeued(request_task)` is called when an incomplete task is re-enqueued through its task handler, because the processor shut down or the reactor failed. After this notification, the job system owns the request again.

To get the IDs of all queued, pending, and in-flight tasks in the pipeline, use `Processor#tracked_request_ids`. For example, you can use the IDs to keep heartbeats alive for tasks that haven't started yet.

## Testing

To execute requests synchronously in tests, use `SynchronousExecutor`. You can use it in place of the asynchronous processor to test your request handling logic without starting the full asynchronous infrastructure.

The [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) and [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gems already integrate it.

```ruby
task = PatientHttp::RequestTask.new(
  request: request,
  task_handler: handler,
  callback: "MyCallback"
)

executor = PatientHttp::SynchronousExecutor.new(
  task,
  config: config,
  on_complete: ->(response) { StatsD.increment("complete") },
  on_error: ->(error) { StatsD.increment("error") }
)

executor.call
```

## Integration

For Sidekiq, see the [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) gem. It provides workers, lifecycle hooks, crash recovery, and a web UI built on this library.

For Solid Queue, see the [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gem. It provides similar features for Solid Queue.

When you use an integration gem, you can make requests through the [standard interface](#standard-interface), so your code doesn't depend on the processor or task handler implementations.

For LLM requests, see the [patient_llm](https://github.com/bdurand/patient_llm) gem. It provides an integration for asynchronous LLM requests over several protocols.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "patient_http"
```

Then run the following command:

```bash
bundle install
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http).

Use the [standardrb](https://github.com/testdouble/standard) style, and lint your code with `standardrb --fix` before you submit it.

The [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) and [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gems each provide a test application for integration testing.

The full test suite needs a Valkey server and an S3Mock server. To start them, run the following command with the included `docker-compose.yml` file:

```bash
docker compose up -d
```

## Further reading

- [Architecture](ARCHITECTURE.md)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
