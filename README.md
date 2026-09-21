# PatientHttp

[![Continuous Integration](https://github.com/bdurand/patient_http/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http.svg)](https://badge.fury.io/rb/patient_http)

*Built for APIs that like to think.*

Generic async HTTP connection pool for Ruby applications that uses Fiber-based concurrency.

## Motivation

An application that makes HTTP requests from a threaded environment often finds that its threads block while they wait for I/O. A single slow API response blocks a whole thread and prevents it from doing other work. When many threads block on HTTP I/O at the same time, throughput collapses.

PatientHttp runs the HTTP requests in a dedicated processor thread that uses the Ruby Fiber scheduler for non-blocking I/O. Your application threads hand each HTTP request to the processor and return immediately. The processor runs hundreds of concurrent HTTP connections on fibers, and it notifies your application through a pluggable callback when a response arrives.

This design keeps your application threads free to do other work while the HTTP requests are in flight.

Usually you use this gem through an integration such as [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) or [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue). These gems provide a request handler for their job processing system, so you can enqueue HTTP requests directly from your application code without coupling that code to the processor. For more information, see [Integration](#integration).

The [patient_llm](https://github.com/bdurand/patient_llm) gem provides an integration that makes large language model requests asynchronously. That was the original reason to build PatientHttp, because an LLM request can take much longer than a typical HTTP request.

## Quick start

### 1. Implement a TaskHandler

The `TaskHandler` is the integration point between the pool and your application. It defines what happens when a request completes, fails, or needs to be retried.

```ruby
class MyTaskHandler < PatientHttp::TaskHandler
  def initialize(job_id)
    @job_id = job_id
  end

  def on_complete(response, callback)
    # Enqueue a message for your application to process the response.
    # Keep this lightweight and thread-safe. It runs on a completion
    # worker thread, at the same time as other completions.
    MyJobSystem.enqueue(callback, :on_complete, response.as_json)
  end

  def on_error(error, callback)
    MyJobSystem.enqueue(callback, :on_error, error.as_json)
  end

  def retry
    # Re-enqueue the original job for retry when the processor
    # shuts down with in-flight requests
    MyJobSystem.enqueue_job(@job_id)
  end
end
```

> **Important:** TaskHandler callbacks run on the completion worker threads of the processor (see `completion_threads`) and not on the reactor thread, so they do not block the event loop. Keep them lightweight anyway: usually a callback only enqueues a message for another system to pick up. A heavy callback competes with the reactor for the GVL, and, because a task stays in the capacity count until its result is delivered, callbacks that back up use up request capacity.
>
> Callbacks must be thread-safe. Results are delivered concurrently on the `completion_threads` workers (default 2), so two callbacks can run at the same time and in an order that does not match the order in which the requests completed. Set `completion_threads: 1` to deliver the results one at a time.
>
> Callbacks must also be idempotent. A callback that raises an error is retried `completion_retries` times (default 2), so a callback that raises an error after it enqueues its message enqueues that message again. Set `completion_retries: 0` if you cannot accept that.

### 2. Create and enqueue requests

```ruby
# Configure the processor
config = PatientHttp::Configuration.new(
  max_connections: 256,
  request_timeout: 60
)

# Start the processor
processor = PatientHttp::Processor.new(config)
processor.start

# Build a request
request = PatientHttp::Request.new(
  :get,
  "https://api.example.com/users/123",
  headers: {"Authorization" => "Bearer token"}
)

# Create a task with your handler
task = PatientHttp::RequestTask.new(
  request: request,
  task_handler: MyTaskHandler.new("job-123"),
  callback: "FetchDataCallback",
  callback_args: {user_id: 123}
)

# Enqueue it
processor.enqueue(task)
```

### 3. Process callbacks

When the HTTP request completes, your `TaskHandler#on_complete` method runs with the `Response` and the callback class name. Your handler then calls the callback in the way that suits your application, for example by enqueuing a background job.

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

## Handling HTTP error responses

By default, an HTTP error status code (4xx or 5xx) counts as a completed request. Check the status with the helper methods on the response:

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

A non-2xx response then calls `TaskHandler#on_error` with an `HttpError` that gives you access to the response:

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

For repeated requests to the same API, use `RequestTemplate` to share configuration:

```ruby
template = PatientHttp::RequestTemplate.new(
  base_url: "https://api.example.com",
  headers: {"Authorization" => "Bearer #{ENV['API_KEY']}"},
  timeout: 60
)

# Build requests from the template
get_request = template.get("/users/123")
post_request = template.post("/users", json: {name: "John"})
```

A template supports every HTTP method—`get`, `head`, `post`, `put`, `patch`, `delete`, and `query`—and it joins the URLs, merges the headers, and encodes the query parameters for you.

## Standard interface

The `PatientHttp` module provides a standard interface that builds and dispatches requests, so you do not work with the processor or the task handlers directly. You can therefore write application code that makes HTTP requests without coupling that code to the async processing infrastructure.

Register a request handler with `PatientHttp.register_handler` to define how requests are dispatched to your job queue or background processing system. After you register it, use the `PatientHttp` class methods or the `RequestHelper` mixin to make async HTTP requests with callbacks.

```ruby
# The handler receives keyword arguments for the request, callback, and any additional callback arguments.
PatientHttp.register_handler do |request:, callback:, callback_args: nil, raise_error_responses: nil|
  # Example integration point. Adapt this to your app.
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

# Now you can make requests directly through the PatientHttp interface with the .request,
# .get, .head, .post, .patch, .put, .delete, and .query class methods:
PatientHttp.get(
  "https://api.example.com/users/123",
  callback: FetchUserCallback,
  callback_args: {user_id: 123}
)
```

If you use the [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) gem or the [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gem, the gem registers the correct handler for you.

### Inline execution

In consoles, tests, and development environments where no job system is configured, register a handler that runs the requests inline—synchronously and in process—instead of dispatching them to a queue:

```ruby
PatientHttp.inline!
```

Every request that you make through the `PatientHttp` interface, or through the `RequestHelper` mixin, then runs immediately through the full request lifecycle, which includes the timeouts, the redirects, and the error wrapping. The callback runs on the calling thread before the request returns. A callback can make more requests, and those also run inline.

```ruby
PatientHttp.inline!
PatientHttp.get("https://api.example.com/users/123", callback: FetchUserCallback)
# FetchUserCallback#on_complete has already run at this point
```

By default, inline requests run against `PatientHttp.default_configuration`, or against a lazily created configuration that includes the secrets registered with `PatientHttp.register_secret` (see [Secrets](#secrets)). You can also pass an explicit configuration:

```ruby
PatientHttp.inline!(config: PatientHttp::Configuration.new(raise_error_responses: true))
```

Use `PatientHttp.inline?` to check whether the inline handler is the registered handler. To run a single request inline without registering a handler, use `PatientHttp.execute_inline(request:, callback:)`.

### RequestHelper mixin

Use `PatientHttp::RequestHelper` when you want a compact API that creates and dispatches async HTTP requests directly from your class.

1. Register a request handler with `PatientHttp.register_handler` to define how requests are dispatched to your job queue or background processing system.
2. Include `PatientHttp::RequestHelper` in your class.
3. Define a `request_template` for a shared `base_url`, shared headers, and a shared timeout. This step is optional.
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

Use `callback_args` to pass your own data through the request and response cycle:

```ruby
task = PatientHttp::RequestTask.new(
  request: request,
  task_handler: handler,
  callback: "FetchDataCallback",
  callback_args: {user_id: 123, request_timestamp: Time.now.iso8601}
)
```

The callback arguments are available on both the `Response` and the `Error` objects:

```ruby
response.callback_args[:user_id]    # Symbol access
response.callback_args["user_id"]   # String access
```

Callback arguments must hold only JSON-native types: `nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, and `Hash`. Hash keys are converted to strings for serialization.

## Response and error objects

The `PatientHttp::Response` object and the error objects serialize to JSON and deserialize from it, so you can safely pass them through a job queue and across a process boundary. You can therefore enqueue the response data or the error data in your `TaskHandler` callbacks and process it asynchronously somewhere else.

Both the response and the error objects provide the `as_json` and `to_json` methods for serialization:

```ruby
def on_complete(response, callback)
  # Serialize the response for background processing
  MyJobSystem.enqueue(callback, :on_complete, response.as_json)
end

def on_error(error, callback)
  # Serialize the error for background processing
  MyJobSystem.enqueue(callback, :on_error, error.as_json)
end
```

To reconstruct the objects, use the `load` class methods:

```ruby
response = PatientHttp::Response.load(json_data)
error = PatientHttp::HttpError.load(json_data)
```

The `Response` object holds the HTTP status code, the headers, the body, and the callback arguments. An error object (`HttpError`, `RedirectError`, or `RequestError`) holds the error message, information about the request, and the callback arguments.

Request and response headers are case insensitive. A request header with a `nil` or empty string value is never sent: setting a header to `nil` or `""` removes it, and a header hash such as `{"X-Header" => nil}` does not set the header at all. A header that appears more than once in the response, such as `set-cookie`, is joined into a single string value.

Response bodies are encoded for JSON serialization. Binary content is Base64 encoded, and large text content is gzipped and then Base64 encoded to make the payload smaller. The decoding happens for you when you call the `body` or `json` methods on the `Response` object.

### Payload stores

For a large request or response payload, configure external storage to keep the serialized JSON payload small. A payload that is larger than the configured threshold is stored externally and fetched when it is needed.

With a job queue or a background processing system, external storage lets you handle large requests and responses without reaching the size limits or the memory limits of the queue messages. Your application code does not need to know that the storage is there.

```ruby
# Register a payload store. Use the file adapter only for development and testing.
config.register_payload_store(:my_store, adapter: :file, directory: "/tmp/payloads")

# Use the ExternalStorage class to set and fetch stored payloads in your callbacks.
storage = PatientHttp::ExternalStorage.new(config)

large_response_data = storage.store(large_response.as_json)
# Returns a reference like: {"$ref" => {"store" => "my_store", "key" => "abc123"}}

small_response_data = storage.store(small_response.as_json, max_size: 1024)
# Returns the original data hash without storing it when the JSON payload is smaller than 1 KB.

storage.storage_ref?(large_response_data) # => true
storage.storage_ref?(small_response_data) # => false

storage.fetch(large_response_data) # Fetches the original data from the store
storage.fetch(small_response_data) # Raises an error, because this is not a reference

storage.delete(large_response_data) # Deletes the stored payload
```

#### File store

For local development and testing.

```ruby
config.register_payload_store(:files, adapter: :file, directory: "/tmp/payloads")
```

#### Redis store

For production deployments where several processes share the state. This store requires the `redis` gem, and the client must respond to `set`, `get`, `del`, and `exists`.

```ruby
redis = Redis.new(url: ENV["REDIS_URL"])
config.register_payload_store(:redis, adapter: :redis, redis: redis, ttl: 86400)
```

Options:

- `redis:` (required)
- `ttl:` in seconds (optional)
- `key_prefix:` (default: `"patient_http:payloads:"`)

#### S3 store

For durable storage that several instances share. This store requires the `aws-sdk-s3` gem.

```ruby
s3 = Aws::S3::Resource.new
bucket = s3.bucket("my-payloads-bucket")
config.register_payload_store(:s3, adapter: :s3, bucket: bucket)
```

Options:

- `bucket:` (required)
- `key_prefix:` (default: `"patient_http/payloads/"`)

#### ActiveRecord store

For database-backed storage with transactional guarantees.

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

Options:

- `model:` (optional, defaults to `PatientHttp::PayloadStore::ActiveRecordStore::Payload`)

#### Custom stores

To implement your own store, subclass `PatientHttp::PayloadStore::Base`:

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

You can register more than one store to migrate between stores. New writes go to the store that you registered last, and every registered store stays available for reads.

## Encryption

When you use PatientHttp with a job queue system, the request and response data is serialized into the queue, for example into Redis or into a database. If this data holds sensitive information, encrypt it.

PatientHttp provides encryption helpers on the `Configuration` object, but the `TaskHandler` implementation must make sure that the serialized data is encrypted. If you use an integration gem such as [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) or [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue), the `TaskHandler` of that gem encrypts the data for you, and you only configure the encryption key or the callables on the `Configuration` object.

If you write your own `TaskHandler`, use `Configuration#encryptor` and call `encrypt` and `decrypt` explicitly wherever your handler serializes or deserializes data.

### Using an encryption key

The simplest option is `encryption_key=`, which configures [ActiveSupport::MessageEncryptor](https://api.rubyonrails.org/classes/ActiveSupport/MessageEncryptor.html) with AES-256-GCM for you:

```ruby
config = PatientHttp::Configuration.new
config.encryption_key = ENV["PATIENT_HTTP_ENCRYPTION_KEY"]
```

To rotate the keys, pass an array. The first key encrypts new data, and every key is tried for decryption:

```ruby
config.encryption_key = [ENV["PATIENT_HTTP_ENCRYPTION_KEY"], ENV["PATIENT_HTTP_OLD_KEY"]]
```

### Using custom callables

For another encryption library, provide callables that take and return raw bytes as a `String`:

```ruby
config.encryption { |bytes| MyEncryption.encrypt(bytes) }
config.decryption { |bytes| MyEncryption.decrypt(bytes) }
```

You can also pass any object that responds to `call`:

```ruby
config.encryption(->(bytes) { MyEncryption.encrypt(bytes) })
config.decryption(->(bytes) { MyEncryption.decrypt(bytes) })
```

### Wiring encryption into a custom TaskHandler

If you write your own `TaskHandler` instead of using one from an integration gem, you must add the encryption yourself. `Configuration#encryptor` returns an `Encryptor` that is built from the configured callables. Call it at every serialization boundary:

```ruby
class MyTaskHandler < PatientHttp::TaskHandler
  def initialize(job_id, configuration:)
    @job_id = job_id
    @configuration = configuration
  end

  def on_complete(response, callback)
    # Encrypt the serialized response before enqueuing
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

# Keep a configuration reference and use config.encryptor where needed
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

### How it works

Encrypted data is stored as `{"__encrypted__" => true, "value" => "<base64>"}`. The `Encryptor` serializes the original hash to JSON, passes the bytes to your callable, and Base64 encodes the result. Decryption reverses the process. A hash without the `"__encrypted__"` key passes through unchanged, so data that was stored before you enabled encryption continues to work.

## Secrets

Requests are serialized into your job queue before they run. If you put a sensitive value directly on a request—an API token in an `Authorization` header, or an API key in a query parameter—that value is written into the queue. You can encrypt the requests in the queue, but it is better to keep the sensitive values off the request.

The secret manager lets you reference a sensitive header value or query parameter value by name instead. The serialized request holds only a reference marker, `{"$secret" => "name"}`, and never the value. The value lives on the `Configuration`, which is on the processor side, and it is resolved at the moment the request is sent.

### Defining secrets

Register the named secrets on the `Configuration`. Give the value directly, or give a block that runs each time the secret is resolved, which is useful when you read the value from the environment on demand:

```ruby
config = PatientHttp::Configuration.new
config.register_secret(:authorization, "Bearer #{ENV['API_TOKEN']}") # static value
config.register_secret(:api_key) { ENV["MY_API_KEY"] } # lazy block
```

If a secret is not found when the request is resolved, PatientHttp raises a `PatientHttp::SecretManager::SecretNotFoundError`, which arrives through the normal request error path.

#### Module-level registration

If an integration gem such as patient_http-sidekiq or patient_http-solid_queue owns the `Configuration`, your application code can have no convenient reference to it, or it can load before the configuration exists. Register the secrets at the module level instead:

```ruby
PatientHttp.register_secret(:authorization, "Bearer #{ENV['API_TOKEN']}")
PatientHttp.register_secret(:api_key) { ENV["MY_API_KEY"] }
```

Module-level secrets apply to `PatientHttp.default_configuration`—immediately if one is already set, or as soon as one is set later—so the order in which your application code and the integration gem register does not matter. An integration gem sets the default configuration at the end of its configure step, and you can also set it yourself:

```ruby
PatientHttp.default_configuration = config
```

Use `PatientHttp.secret_registered?(name)` to check whether a secret is available, either at the module level or on the default configuration.

### Referencing secrets when building a request

Use `PatientHttp.secret(name)` wherever you would put a sensitive header value or query parameter value. No value is needed, or available, at build time:

```ruby
PatientHttp.get(
  "https://api.example.com/data",
  callback: MyCallback,
  headers: {"Authorization" => PatientHttp.secret(:api_token)},
  params: {"api_key" => PatientHttp.secret(:api_key), "page" => 2}
)
```

The request serializes the secret header as `{"$secret" => "api_token"}` and keeps the secret query parameter out of the URL. A parameter that is not a secret, such as `page`, is still folded into the URL. The processor resolves both just before it sends the request: it sets the header to the resolved value, and it appends the resolved query parameter to the URL.

## Request preprocessors

A preprocessor changes a request just before it is sent, most often to sign it. A signing scheme such as AWS SigV4 computes values over the final outgoing request—the method, the URL, the headers, and the body—and sets several headers, which you cannot express as a static header value at build time.

Like a secret, a preprocessor is registered on the `Configuration` and referenced from a request by name only. The serialized request carries only the name, so the signing logic and its credentials stay on the processor side and are never written to the job queue.

### Defining preprocessors

Register a named preprocessor as a block, or as a callable that takes a single argument:

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

The argument is a `PatientHttp::OutgoingRequest`, which is a view of the request as it is about to be sent, after the secret references are resolved and after the `x-request-id` and default `User-Agent` headers are set. It provides:

- `http_method`, `url`, and `body`: read-only values. The URL includes the resolved secret query parameters.
- `headers`: case insensitive headers that you can change.
- `add_param(name, value)`: appends a query parameter to the URL, for a scheme that signs the query parameters.

### Attaching preprocessors to a request

Reference the registered preprocessors by name when you build a request:

```ruby
PatientHttp.post(
  "https://api.example.com/data",
  callback: MyCallback,
  json: {value: 1},
  preprocessors: :aws_sigv4
)
```

You can give several preprocessors as an array. They run in order, and each one sees the changes that the earlier ones made. `RequestTemplate` and the `request_template` method of the `RequestHelper` mixin accept `preprocessors:` as a default for the whole template, and the `async_*` helpers of the mixin accept `preprocessors:` for a single request.

If a request references a preprocessor name that is not registered, PatientHttp raises a `PatientHttp::RequestPreparer::PreprocessorNotFoundError`, which arrives through the normal request error path.

When the processor follows a redirect, it runs the preprocessors again against each redirect URL, so the signatures stay valid. On a cross-origin redirect, it drops the preprocessors completely, in the same way that it strips the `Authorization` and `Cookie` headers, so the signed credentials never go to an unexpected origin.

## Redirects

The processor follows a redirect response (300, 301, 302, 303, 307, or 308) that carries a `Location` header, up to `max_redirects` hops. It follows a 300 response only when the server names a preferred choice in `Location`. A redirect loop raises `RecursiveRedirectError`, and more hops than the limit raises `TooManyRedirectsError`. A redirect that the processor does not follow reaches the callback as a normal response.

The HTTP method of the redirected request follows RFC 9110:

| Status | Method |
| --- | --- |
| 301, 302 | `POST` becomes `GET`, and the body is dropped. Every other method, which includes `HEAD`, `PUT`, `DELETE`, and `QUERY`, keeps its body. |
| 303 | `GET` and `HEAD` stay the same. Every other method becomes `GET`, and the body is dropped. |
| 300, 307, 308 | The method and the body stay the same. |

The QUERY specification states that the POST-to-GET exception on 301 and 302 does not apply to `QUERY`. A redirected `QUERY` is therefore sent again as a `QUERY` with its body, and a 303 changes it to a `GET`.

### Preventing method changes

Set `follow_method_changing_redirects: false` to stop the processor from following a redirect that would change the HTTP method. A `POST` that receives a 302 then completes with the 302 response instead of being sent again as a `GET`. The processor still follows a redirect that keeps the method, such as a `PUT` on a 301, or any method on a 307. You can set the option on the `Configuration` or on a single `Request`. The request value takes precedence.

```ruby
config = PatientHttp::Configuration.new(follow_method_changing_redirects: false)

# Or per request
request = PatientHttp::Request.new(:post, "https://api.example.com/submit", body: payload, follow_method_changing_redirects: false)
```

### Stripping headers on redirects

The `Authorization` and `Cookie` headers are always removed on a cross-origin redirect. To make sure that another sensitive header never goes to a redirect target, list it in `redirect_strip_headers`. The header names are matched case insensitively. A listed header is removed from every redirected request, whether the redirect is same-origin or not.

```ruby
config = PatientHttp::Configuration.new(redirect_strip_headers: ["X-Api-Key", "X-Internal-Token"])

# Or per request; these are stripped in addition to the configured headers
request = PatientHttp::Request.new(:get, "https://api.example.com/data", headers: headers, redirect_strip_headers: "X-Signature")

# The same options are accepted by PatientHttp.request, the async_* helpers, and RequestTemplate
PatientHttp.get("https://api.example.com/data", callback: FetchCallback, redirect_strip_headers: "X-Signature")
```

The per-request header names survive the serialization into the job queue, so they apply whichever process follows the redirect.

Stripping applies to the headers that are set on the request. The preprocessors run again on each same-origin redirect and can add headers after the strip, so a header that a preprocessor sets does go to the redirect target. When a redirect changes the method and drops the body, the headers that describe the body are removed as well: `Content-Type`, `Content-Length`, `Content-Encoding`, `Content-Language`, and `Content-Location`.

## Troubleshooting

### Warning: `ThreadError: Attempt to unlock a mutex which is not locked`

In some Ruby versions, a warning like this can appear in your logs:

```
warn: Async::Task: Async::Pool::Controller Gardener [...]
    | Task may have ended with unhandled exception.
    |   ThreadError: Attempt to unlock a mutex which is not locked
    |   → .../async-pool-x.y.z/lib/async/pool/controller.rb:132 in `synchronize'
```

The cause is [Ruby bug #20907](https://bugs.ruby-lang.org/issues/20907), which is also described in [socketry/async#424](https://github.com/socketry/async/issues/424). Under the fiber scheduler, a fiber that is interrupted while it waits on a `ConditionVariable` does not acquire its mutex again before it unwinds, which raises a `ThreadError` that does not describe a real problem. The warning appears whenever a pooled HTTP client closes while the background "gardener" task of its connection pool is idle, for example when a connection is evicted after a connection error, when the least recently used client is evicted because the pool is full, or when the processor shuts down.

The warning is harmless: the connections still close correctly, and only the log message is wrong. To remove it, upgrade Ruby. The bug is fixed in Ruby 3.2.7, 3.3.7, and 3.4 and later.

## Configuration

```ruby
config = PatientHttp::Configuration.new(
  # Maximum concurrent HTTP requests (default: 256)
  max_connections: 256,

  # Default timeout for HTTP requests in seconds (default: 60)
  request_timeout: 60,

  # Timeout for graceful shutdown in seconds (default: 30)
  shutdown_timeout: 30,

  # Maximum response body size in bytes (default: 1 MB)
  max_response_size: 1024 * 1024,

  # Default User-Agent header (default: "PatientHttp")
  user_agent: "MyApp/1.0",

  # Treat non-2xx responses as errors by default (default: false)
  raise_error_responses: false,

  # Maximum redirects to follow (default: 5, 0 disables)
  max_redirects: 5,

  # Follow redirects that must change the HTTP method, such as POST to GET on
  # a 302 (default: true). When false, those requests receive the redirect response.
  follow_method_changing_redirects: true,

  # Header names (case insensitive) always stripped from redirected requests
  # (default: []). Authorization and Cookie are always stripped on cross-origin
  # redirects.
  redirect_strip_headers: ["X-Api-Key", "X-Internal-Token"],

  # Maximum number of connections to one host (default: nil, unlimited)
  max_connections_per_host: 32,

  # Maximum number of hosts to keep persistent connections for (default: 100)
  connection_pool_size: 100,

  # Connection timeout in seconds (default: nil, uses request_timeout)
  connection_timeout: 10,

  # HTTP/HTTPS proxy URL (default: nil)
  proxy_url: "http://proxy.example.com:8080",

  # Retries for failed requests (default: 3)
  retries: 3,

  # Force the HTTP protocol to :http1 or :http2 (default: nil, negotiates with
  # the server and prefers HTTP/2 for HTTPS). Forcing :http1 also limits the TLS
  # ALPN advertisement to http/1.1, which works around SSL-intercepting proxies
  # that do not handle HTTP/2 correctly.
  protocol: nil,

  # Number of threads that deliver completed results (default: 2)
  completion_threads: 2,

  # Retries before a failed delivery is reported through completion_failed
  # (default: 2)
  completion_retries: 2,

  # Logger instance (default: Logger to STDERR at ERROR level)
  logger: Logger.new($stdout)
)

# Register a named secret to reference a sensitive header or query parameter
# indirectly (see Secrets)
config.register_secret(:api_token, ENV["MY_API_TOKEN"])
```

### Tuning tips

- **max_connections**: Each connection uses memory and file descriptors. A tuned system can handle thousands.
- **max_connections_per_host**: Limits the number of sockets per host. The default is unlimited. Set a value such as 32 for a deployment with high concurrency, so that one host cannot use every file descriptor. Make sure that the file descriptor limit of the process covers `max_connections`, plus the pooled idle host connections, plus the connections of your application.
- **request_timeout**: Set this value from the response times that you expect. An AI or LLM API can need minutes.
- **connection_pool_size**: Increase this value for an application that calls many different API hosts.
- **max_response_size**: Keeps the memory usage bounded. A large response can need external payload storage. For a compressed response, the limit applies to the inflated bytes.
- **Response compression**: A request asks for `gzip` by default, and the body is inflated on a completion worker thread. Set `accept-encoding` on a request to change this: `identity` skips the compression, and any other encoding arrives still encoded, with its `content-encoding` header kept, so that you can decode it yourself.
- **completion_threads**: The number of threads that decode the responses and deliver the results. The default is 2. Increase this value when your callbacks do heavier work, such as serialization or encryption, and the completions back up behind them. Any value above 1 delivers the results concurrently, so the `TaskHandler` callbacks and the completion-time observers must be thread-safe. Use 1 to deliver the results one at a time.
- **completion_retries**: The number of delivery retries before a result is reported through `completion_failed`. The default is 2. A retry calls `on_complete` or `on_error` again, so a handler that raises an error *after* it enqueues its message delivers that message twice. Make your handlers idempotent, or set `completion_retries: 0` to report the first failure without a retry.
- **shutdown_timeout**: Set this value below the termination window of your process supervisor, so that the drain, which includes the completions that were handed off, finishes before the supervisor stops the process.

## Processor lifecycle

The processor moves through these states:

```
stopped -> starting -> running -> draining -> stopping -> stopped
```

- **stopped**: Processes no requests.
- **starting**: Initializes the reactor thread.
- **running**: Accepts and processes requests.
- **draining**: Rejects new requests and completes the in-flight ones.
- **stopping**: Shuts down and re-enqueues the incomplete requests.

```ruby
processor = PatientHttp::Processor.new(config)

processor.start              # Start processing
processor.running?           # => true

processor.drain              # Stop accepting new requests
processor.draining?          # => true

processor.stop(timeout: 25)  # Graceful shutdown
processor.stopped?           # => true
```

When the processor stops while requests are in flight, it calls `TaskHandler#retry` on each incomplete task, so that the task can be enqueued again.

### Observing the processor

Register an observer to monitor the processor events:

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

An observer can also track the full task pipeline:

- `request_enqueued(request_task)` runs when a task is announced to the processor, before the task is visible to the reactor. It always arrives before `request_start`, so you can set up durable tracking, for example a crash-recovery registry entry, before `Processor#enqueue` returns or raises an error.
- `request_rejected(request_task)` runs when the processor does not accept an announced task, because it is not running or is at maximum capacity. Tear down anything that you set up in `request_enqueued`.
- `request_requeued(request_task)` runs when an incomplete task is re-enqueued through its task handler, after a processor shutdown or a reactor failure. The job system owns the request again once this event is sent.

Use `Processor#tracked_request_ids` to get the IDs of all the tasks in the pipeline, which are the queued, pending, and in-flight tasks. You can use these IDs, for example, to keep the heartbeats alive for the tasks that have not started yet.

## Testing

Use `SynchronousExecutor` to run requests synchronously in your tests. It replaces the async processor, so that you can test your request handling logic without starting the full async infrastructure.

The [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) and [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gems integrate it for you.

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

For the Sidekiq integration, see the [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) gem, which provides workers, lifecycle hooks, crash recovery, and a web UI that are built on this library.

For the Solid Queue integration, see the [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gem, which provides the same features for Solid Queue.

With an integration gem, use the [standard interface](#standard-interface) to make requests without coupling your code to the processor or to the task handler.

For large language model (LLM) requests, see the [patient_llm](https://github.com/bdurand/patient_llm) gem, which makes LLM requests asynchronously through several protocols.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "patient_http"
```

Then run:

```bash
bundle install
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http).

Use the [standardrb](https://github.com/testdouble/standard) syntax, and lint your code with `standardrb --fix` before you submit the pull request.

The [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) and [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gems each provide a test application for integration testing.

To run the full test suite, start a valkey server and an s3mock server with the included docker-compose.yml file.

## Further reading

- [Architecture](ARCHITECTURE.md)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
