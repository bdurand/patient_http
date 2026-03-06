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

In general you will want to use this gem through an integration like [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) or [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue). These gems provide a request handler that integrates with their respective job processing systems, allowing you to enqueue HTTP requests directly from your application code without coupling it to the underlying processor implementation. See the [integration](#integration) section for details.

## Quick Start

### 1. Implement a TaskHandler

The `TaskHandler` is the integration point between the pool and your application. It defines what happens when a request completes, fails, or needs to be retried.

```ruby
class MyTaskHandler < PatientHttp::TaskHandler
  def initialize(job_id)
    @job_id = job_id
  end

  def on_complete(response, callback)
    # Enqueue a message for your application to process the response.
    # Keep this lightweight -- don't do heavy processing here since
    # it runs on the processor thread.
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

> **Important:** TaskHandler callbacks run on the processor's reactor thread. They should be lightweight and fast -- typically just enqueuing a message for another system to pick up. Doing heavy processing in a callback will block the reactor and delay other in-flight requests.

### 2. Create and Enqueue Requests

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

### 3. Process Callbacks

When the HTTP request completes, your `TaskHandler#on_complete` is called with the `Response` and callback class name. Your handler is responsible for invoking the callback in whatever way makes sense for your application (e.g., enqueuing a background job).

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

## Handling HTTP Error Responses

By default, HTTP error status codes (4xx, 5xx) are treated as completed requests. You can check the status using helper methods on the response:

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

When enabled, non-2xx responses call `TaskHandler#on_error` with an `HttpError` that provides access to the response:

```ruby
def on_error(error)
  if error.is_a?(PatientHttp::HttpError)
    puts error.status           # HTTP status code
    puts error.url              # Request URL
    puts error.response.body    # Response body
  end
end
```

## Request Templates

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

Templates support all HTTP methods (`get`, `post`, `put`, `patch`, `delete`) and handle URL joining, header merging, and query parameter encoding.

## Standard Interface

The `PatientHttp` module provides a standard interface for building and dispatching requests without needing to directly interact with the processor or task handlers. This allows you to write application code that makes HTTP requests without coupling it to the underlying async processing infrastructure.

You will need to register a request handler with `PatientHttp.register_handler` that defines how requests are dispatched to your job queue or background processing system. Once registered, you can use the `PatientHttp` class methods or the `RequestHelper` mixin to make async HTTP requests with callbacks.

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
# .get, .post, .patch, .put, and .delete class methods:
PatientHttp.get(
  "https://api.example.com/users/123",
  callback: FetchUserCallback,
  callback_args: {user_id: 123}
)
```

If you are using the [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) gem or the [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gem, the appropriate handler will automatically be registered for you.

### RequestHelper Mixin

Use `PatientHttp::RequestHelper` when you want a simple API for creating and dispatching async HTTP requests directly from your class.

1. Register a request handler with `PatientHttp.register_handler` that defines how requests are dispatched to your job queue or background processing system.
2. Include `PatientHttp::RequestHelper` in your class.
3. Optionally define a `request_template` for shared `base_url`, headers, and timeout.
4. Call `async_get`, `async_post`, `async_put`, `async_patch`, `async_delete`, or `async_request`.

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

## Callback Arguments

Pass custom data through the request/response cycle using `callback_args`:

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

Callback args must contain only JSON-native types (`nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, `Hash`). Hash keys are converted to strings for serialization.

## Response and Error Objects

The `PatientHttp::Response` and error objects are designed to be serializable and deserializable as JSON, making them safe to pass through job queues and across process boundaries. This allows you to enqueue the response or error data in your `TaskHandler` callbacks and process them asynchronously in another context.

Both response and error objects provide `as_json` and `to_json` methods for serialization:

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

When deserializing, use the `load` class methods to reconstruct the objects:

```ruby
response = PatientHttp::Response.load(json_data)
error = PatientHttp::HttpError.load(json_data)
```

The `Response` object includes the HTTP status code, headers, body, and callback arguments. Error objects (`HttpError`, `RedirectError`, `RequestError`) include the error message, context about the request, and callback arguments.

Response bodies are automatically encoded for JSON serialization. Binary content is Base64 encoded, and large text content is gzipped and then Base64 encoded to reduce payload size. Decoding is handled transparently when you access the `body` or `json` methods on the `Response` object.

### Payload Stores

For large request/response payloads, you can configure external storage to keep serialized JSON payloads small. Payloads exceeding the configured threshold are automatically stored externally and fetched on demand.

If you are using a job queue or background processing system, this allows you to handle large requests or responses without hitting size limits or memory constraints on queue message payloads. The use of external storage is transparent to your application code.

```ruby
# Register a payload store (see below for options; the file adapter should only be used for development/testing)
config.register_payload_store(:my_store, adapter: :file, directory: "/tmp/payloads")

# Use the ExternalStorage class to set and fetch stored payloads in your callbacks.
storage = PatientHttp::ExternalStorage.new(config)

large_response_data = storage.store(large_response.as_json)
# Returns a reference like: {"$ref" => {"store" => "my_store", "key" => "abc123"}}

small_response_data = storage.store(small_response.as_json, max_size: 1024)
# Will not store the payload and returns the original data hash if the JSON payload is under 1KB.

storage.storage_ref?(large_response_data) # => true
storage.storage_ref?(small_response_data) # => false

storage.fetch(large_response_data) # Fetches the original data from the store
storage.fetch(small_response_data) # Raises an error since this is not a reference

storage.delete(large_response_data) # Deletes the stored payload
```

#### File Store

For development and testing:

```ruby
config.register_payload_store(:files, adapter: :file, directory: "/tmp/payloads")
```

#### Redis Store

For production with shared state across processes:

```ruby
redis = RedisClient.new(url: ENV["REDIS_URL"])
config.register_payload_store(:redis, adapter: :redis, redis: redis, ttl: 86400)
```

Options: `redis:` (required), `ttl:` (seconds, optional), `key_prefix:` (default: `"patient_http:payloads:"`)

#### S3 Store

For durable storage across instances (requires `aws-sdk-s3` gem):

```ruby
s3 = Aws::S3::Resource.new
bucket = s3.bucket("my-payloads-bucket")
config.register_payload_store(:s3, adapter: :s3, bucket: bucket)
```

Options: `bucket:` (required), `key_prefix:` (default: `"patient_http/payloads/"`)

#### ActiveRecord Store

For database-backed storage with transactional guarantees:

```ruby
config.register_payload_store(:database, adapter: :active_record)
```

This requires a database migration. Copy the migration from the gem:

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

Options: `model:` (optional, defaults to built-in `PatientHttp::PayloadStore::ActiveRecordStore::Payload`)

#### Custom Stores

Implement your own by subclassing `PatientHttp::PayloadStore::Base`:

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

Multiple stores can be registered for migration purposes. The last registered store is used for new writes; all registered stores remain available for reads.

## Configuration

```ruby
config = PatientHttp::Configuration.new(
  # Maximum concurrent HTTP requests (default: 256)
  max_connections: 256,

  # Default timeout for HTTP requests in seconds (default: 60)
  request_timeout: 60,

  # Timeout for graceful shutdown in seconds (default: 23)
  shutdown_timeout: 23,

  # Maximum response body size in bytes (default: 1MB)
  max_response_size: 1024 * 1024,

  # Default User-Agent header (default: "PatientHttp")
  user_agent: "MyApp/1.0",

  # Treat non-2xx responses as errors by default (default: false)
  raise_error_responses: false,

  # Maximum redirects to follow (default: 5, 0 disables)
  max_redirects: 5,

  # Maximum host maintain persistent connections for (default: 100)
  connection_pool_size: 100,

  # Connection timeout in seconds (default: nil, uses request_timeout)
  connection_timeout: 10,

  # HTTP/HTTPS proxy URL (default: nil)
  proxy_url: "http://proxy.example.com:8080",

  # Retries for failed requests (default: 3)
  retries: 3,

  # Logger instance (default: Logger to STDERR at ERROR level)
  logger: Logger.new($stdout)
)
```

### Tuning Tips

- **max_connections**: Each connection uses memory and file descriptors. A tuned system can handle thousands.
- **request_timeout**: Set based on expected API response times. AI/LLM APIs may need minutes.
- **connection_pool_size**: Increase for applications calling many different API hosts.
- **max_response_size**: Keeps memory usage bounded. Large responses may need external payload storage.

## Processor Lifecycle

The processor transitions through these states:

```
stopped -> starting -> running -> draining -> stopping -> stopped
```

- **stopped**: Not processing requests
- **starting**: Initializing the reactor thread
- **running**: Accepting and processing requests
- **draining**: Rejecting new requests, completing in-flight ones
- **stopping**: Shutting down, re-enqueuing incomplete requests

```ruby
processor = PatientHttp::Processor.new(config)

processor.start              # Start processing
processor.running?           # => true

processor.drain              # Stop accepting new requests
processor.draining?          # => true

processor.stop(timeout: 25)  # Graceful shutdown
processor.stopped?           # => true
```

When the processor stops with in-flight requests, it calls `TaskHandler#retry` on each incomplete task so they can be re-enqueued.

### Observing the Processor

Register observers to monitor processor events:

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

## Testing

Use `SynchronousExecutor` to execute requests synchronously in tests. This class can be used in place of the async processor for testing your request handling logic without needing to start the full async infrastructure.

It is integrated automatically in the [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) and [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gems.

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

For Sidekiq integration, see the [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) gem which provides workers, lifecycle hooks, crash recovery, and a Web UI built on this library.

For Solid Queue integration, see the [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gem which provides similar functionality for Solid Queue.

When using an integration gem, you can use the [standard interface](#standard-interface) to make requests without coupling your code to the underlying processor or task handler implementations.

## Installation

Add this line to your application's Gemfile:

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

## Further Reading

- [Architecture](ARCHITECTURE.md)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
