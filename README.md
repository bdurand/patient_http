# PatientHttp

[![Continuous Integration](https://github.com/bdurand/patient_http/actions/workflows/continuous_integration.yml/badge.svg)](https://github.com/bdurand/patient_http/actions/workflows/continuous_integration.yml)
[![Ruby Style Guide](https://img.shields.io/badge/code_style-standard-brightgreen.svg)](https://github.com/testdouble/standard)
[![Gem Version](https://badge.fury.io/rb/patient_http.svg)](https://badge.fury.io/rb/patient_http)

*Built for APIs that like to think.*

This gem runs HTTP requests on a dedicated async I/O processor and passes each result to a callback service. Application threads don't wait for HTTP responses, so they're free to do other work while requests are in flight.

## Motivation

In a threaded application, a thread that makes an HTTP request waits for the response. A slow API response holds the thread for the full duration, so the thread can't do other work. When many threads wait on HTTP requests at the same time, throughput drops.

This gem runs HTTP requests in a dedicated processor thread that uses Ruby's fiber scheduler for non-blocking I/O. An application thread hands off a request to the processor and returns immediately. The processor runs hundreds of HTTP requests at the same time. When a response arrives, the processor passes it to your callback service through a job system.

## Quick start

The processor needs a process to run in and a job system to deliver the results. Install the integration gem for your job system, which handles both:

- [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) for Sidekiq
- [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) for Solid Queue

For large language model (LLM) requests, use [patient_llm](https://github.com/bdurand/patient_llm), which builds on this gem. LLM requests can take much longer than typical HTTP requests, which was the original reason for this gem.

### 1. Install the gem

Add the integration gem for your job system to your Gemfile. The integration gem depends on this gem, so you don't need to add `patient_http` too.

```ruby
gem "patient_http-sidekiq"
```

No other setup is required. When the integration gem loads, it registers the request handler and connects the processor to the startup and shutdown of your job system. You don't need to write an initializer or call a setup method.

### 2. Create a callback service

Define a callback service class with `on_complete` and `on_error` instance methods. The callback service runs in a background job, so it can do slow work.

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

### 3. Make HTTP requests

```ruby
PatientHttp.get(
  "https://api.example.com/users/123",
  callback: FetchUserCallback,
  callback_args: {user_id: 123}
)
```

The call returns immediately. The processor runs the request, and when the request finishes, a background job calls your callback's `on_complete` method. If the request fails, the job calls `on_error` instead.

Every option has a working default. To change the defaults, see [Configuration](#configuration).

### Run requests without a job system

In consoles, tests, and development environments without a job system, run requests inline:

```ruby
PatientHttp.inline!
```

After this call, each request made with the `PatientHttp` module methods runs immediately on the calling thread. The request goes through the full request lifecycle, including timeouts, redirects, and error handling, and the callback runs before the request method returns.

```ruby
PatientHttp.inline!
PatientHttp.get("https://api.example.com/users/123", callback: FetchUserCallback)
# FetchUserCallback#on_complete has already run.
```

Requests that callbacks make also run inline. To check whether the inline handler is registered, call `PatientHttp.inline?`. To run one request inline without registering a handler, call `PatientHttp.execute_inline(request:, callback:)`.

## Usage

### Make requests

The `PatientHttp` module has a method for each HTTP method: `get`, `head`, `post`, `put`, `patch`, `delete`, and `query`. The methods take the same options. `PatientHttp.request` takes the HTTP method as its first argument.

```ruby
PatientHttp.post(
  "https://api.example.com/users",
  json: {name: "John", email: "john@example.com"},
  callback: CreateUserCallback,
  callback_args: {source: "signup"}
)
```

The methods take these options:

| Option | Description |
| --- | --- |
| `callback:` | Required. The callback service class, or its name. |
| `callback_args:` | A Hash of arguments that the callback reads from the response or error. See [Callback arguments](#callback-arguments). |
| `headers:` | The request headers. |
| `body:` | The request body. GET, HEAD, and DELETE requests can't have a body. |
| `json:` | An object to send as a JSON body. Can't be combined with `body:`. |
| `params:` | Query parameters to add to the URL. |
| `timeout:` | The request timeout in seconds. |
| `raise_error_responses:` | Whether to treat non-2xx responses as errors. See [Handle HTTP error responses](#handle-http-error-responses). |
| `max_redirects:` | The maximum number of redirects to follow for this request. `0` turns off redirects. |
| `follow_method_changing_redirects:` | Whether to follow redirects that change the HTTP method. See [Redirects](#redirects). |
| `redirect_strip_headers:` | The names of headers to remove from redirected requests. |
| `preprocessors:` | The names of registered [preprocessors](#request-preprocessors) to run on the request. |
| `processor:` | The name of the processor that runs the request. See [Named processors](#named-processors). |

For more control, build a `PatientHttp::Request` object and pass it to `PatientHttp.execute`:

```ruby
request = PatientHttp::Request.new(:get, "https://api.example.com/users/123",
  headers: {"Authorization" => PatientHttp.secret(:api_token)},
  params: {include: "profile"},
  timeout: 30
)
PatientHttp.execute(request: request, callback: FetchUserCallback, callback_args: {user_id: 123})
```

Application code that uses these methods never names the job system. To move to another job system, change the integration gem in your Gemfile.

### Handle HTTP error responses

By default, HTTP error status codes (4xx and 5xx) are treated as completed requests and passed to `on_complete`. To check the status, use `response.success?`, `response.client_error?`, or `response.server_error?`:

```ruby
class ApiCallback
  def on_complete(response)
    if response.success?
      process_data(response.json)
    elsif response.client_error?
      handle_client_error(response.status, response.body)
    elsif response.server_error?
      handle_server_error(response.status, response.body)
    end
  end

  def on_error(error)
    Rails.logger.error("Request failed: #{error.message}")
  end
end
```

The `on_error` callback runs when the request raises an exception, such as a timeout or a connection failure. To treat HTTP errors as exceptions too, set the `raise_error_responses` option. With this option, a non-2xx response calls `on_error` with a `PatientHttp::HttpError`:

```ruby
PatientHttp.get("https://api.example.com/data", callback: ApiCallback, raise_error_responses: true)
```

An `HttpError` gives you access to the request and the response:

```ruby
def on_error(error)
  if error.is_a?(PatientHttp::HttpError)
    puts error.status              # HTTP status code
    puts error.url                 # Request URL
    puts error.http_method         # HTTP method
    puts error.response.body       # Response body
    puts error.response.headers    # Response headers
    puts error.response.json       # Response body parsed as JSON
  end
end
```

A 4xx response raises a `PatientHttp::ClientError`, and a 5xx response raises a `PatientHttp::ServerError`. Both are subclasses of `HttpError`.

To make `raise_error_responses` the default for every request, set it in the [configuration](#configuration).

### Callback arguments

To pass data to your callbacks, use the `callback_args` option:

```ruby
PatientHttp.get(
  "https://api.example.com/users/#{user_id}",
  callback: FetchUserCallback,
  callback_args: {user_id: user_id, requested_at: Time.now.iso8601}
)
```

The `response.callback_args` and `error.callback_args` methods return the arguments:

```ruby
response.callback_args[:user_id]
response.callback_args["user_id"]
```

The `callback_args` value follows these rules:

- It must be a Hash, or respond to `to_h`, and contain only JSON-native types: `nil`, `true`, `false`, `String`, `Integer`, `Float`, `Array`, and `Hash`.
- Hash keys are converted to strings, including the keys of nested hashes and of hashes in arrays.
- You can read the arguments with symbol or string keys: `callback_args[:user_id]` or `callback_args["user_id"]`.
- Reading a key that isn't set raises a `KeyError`. To get a default value instead, use `callback_args.fetch(:user_id, nil)`.

### Use request templates

To share settings across requests to the same API, use `PatientHttp::RequestTemplate`:

```ruby
template = PatientHttp::RequestTemplate.new(
  base_url: "https://api.example.com",
  headers: {"Authorization" => PatientHttp.secret(:api_token)},
  timeout: 60
)

request = template.get("/users/123")
PatientHttp.execute(request: request, callback: FetchUserCallback)
```

A template has a method for each HTTP method. The template joins each path with the base URL, and merges the headers and query parameters of each request with its own. If the template doesn't set a `timeout`, the configured `request_timeout` applies.

### Use the RequestHelper module

For a class that makes many requests, include `PatientHttp::RequestHelper`. The module adds the `async_get`, `async_head`, `async_post`, `async_put`, `async_patch`, `async_delete`, `async_query`, and `async_request` methods. To set shared options such as `base_url`, `headers`, and `timeout`, use the `request_template` class method:

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

The `async_*` methods take the same options as the `PatientHttp` module methods. Paths are relative to the template's `base_url`. A subclass uses the template of its superclass unless it declares its own.

## Configuration

All configuration is optional. To set options, call `PatientHttp.configure` in an initializer. If an integration gem is loaded, the method yields that gem's configuration, which adds the options for the job system to the options below.

Every call yields the same configuration object, so options accumulate. Several initializers can each set options without overwriting one another.

```ruby
PatientHttp.configure do |config|
  # Maximum concurrent HTTP requests (default: 256).
  config.max_connections = 256

  # Maximum connections to each host (default: nil, no limit).
  config.max_connections_per_host = 32

  # Default timeout for HTTP requests in seconds (default: 60).
  config.request_timeout = 60

  # Timeout for graceful shutdown in seconds (default: 30).
  config.shutdown_timeout = 30

  # Maximum response body size in bytes (default: 1MB). Larger responses raise
  # ResponseTooLargeError.
  config.max_response_size = 1024 * 1024

  # Default User-Agent header for all requests (default: "PatientHttp").
  config.user_agent = "MyApp/1.0"

  # Whether to raise HttpError for non-2xx responses by default (default: false).
  config.raise_error_responses = false

  # Maximum number of redirects to follow (default: 5; 0 turns off redirects).
  config.max_redirects = 5

  # Whether to follow redirects that change the HTTP method, such as POST to
  # GET on a 302 (default: true). If false, the request gets the redirect
  # response.
  config.follow_method_changing_redirects = true

  # Names of headers to remove from all redirected requests (default: []).
  # Names are case insensitive. Authorization and Cookie are always removed on
  # cross-origin redirects.
  config.redirect_strip_headers = ["X-Api-Key", "X-Internal-Token"]

  # Maximum number of host clients to pool (default: 100).
  config.connection_pool_size = 100

  # Timeout in seconds to open a connection, including the TCP connect and the
  # TLS handshake (default: nil, no limit). It doesn't limit the wait for a
  # response; request_timeout does that.
  config.connection_timeout = 10

  # TCP keepalive for pooled connections (default: nil, the kernel sends no
  # probes). A number sets the idle seconds before the first probe. A Hash also
  # sets the interval and the probe count, for example
  # {idle: 30, interval: 10, count: 3}. The Hash must contain :idle. The
  # :interval default is 10 seconds, and the :count default is 3 probes.
  config.tcp_keepalive = 30

  # Seconds that sent data can stay unacknowledged before the kernel closes the
  # connection (default: nil, the kernel default applies). Sets
  # TCP_USER_TIMEOUT, which is available only on Linux.
  config.tcp_user_timeout = 30

  # HTTP or HTTPS proxy URL (default: nil). Supports authentication, for
  # example "http://user:pass@proxy.example.com:8080".
  config.proxy_url = "http://proxy.example.com:8080"

  # Number of retries for failed requests (default: 3).
  config.retries = 3

  # HTTP protocol, :http1 or :http2 (default: nil, negotiated with the server,
  # with HTTP/2 preferred for HTTPS). The :http1 value also limits the TLS ALPN
  # advertisement to http/1.1, which can work around proxies that intercept SSL
  # and don't handle HTTP/2 correctly.
  config.protocol = nil

  # Number of threads that decode responses and deliver results (default: 2).
  config.completion_threads = 2

  # Number of times to retry result delivery before the failure is reported
  # (default: 2).
  config.completion_retries = 2

  # Size in bytes above which payloads are stored externally when a payload
  # store is configured (default: 64KB).
  config.payload_store_threshold = 64 * 1024

  # Logger (default: a Logger that writes errors to standard error).
  config.logger = Rails.logger
end
```

`PatientHttp.configuration` returns the same object outside a `configure` block.

For the options that each job system adds, see the documentation for [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq#configuration) and [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue#configuration).

### Named processors

Named processors are available only when an integration gem is loaded. The integration gems add the `config.processor` method.

By default, all requests share one processor and one `max_connections` limit. If one process runs workloads with very different profiles, such as slow LLM API calls and fast webhook deliveries, a burst of one workload can use all the capacity that the other needs. Named processor profiles keep the workloads separate:

```ruby
PatientHttp.configure do |config|
  config.processor(:llm, max_connections: 200, request_timeout: 120)
  config.processor(:webhooks, max_connections: 64, request_timeout: 10)
end
```

Each profile runs as an independent processor in the process, with its own capacity, timeouts, and threads. Profile options override the top-level configuration. The profiles share every option that they don't override, such as secrets, preprocessors, payload stores, encryption, and the logger. The `:default` processor always exists.

To send a request to a processor, set the `processor:` option on the request method, on a `Request`, or on a `RequestTemplate`:

```ruby
PatientHttp.post(url, callback: MyCallback, processor: :llm)
```

For how the processor name is kept through retries and crash recovery, see the documentation for your integration gem.

### Tuning tips

- `max_connections`: Set this based on your system's resources. Each connection uses memory and a file descriptor. A tuned system with enough resources can handle thousands of concurrent connections.
- `max_connections_per_host`: Limits the sockets open to each host. The default is no limit. For high concurrency, set a value such as 32, so that one host can't use every file descriptor. Make sure that the process file descriptor limit covers `max_connections`, plus idle pooled connections, plus the application's own connections.
- `request_timeout`: Set this based on the response times of the APIs that you call. AI APIs can take minutes to respond while they generate content.
- `connection_timeout`: Limits only the TCP connect and the TLS handshake. Set it to fail fast when a host doesn't answer. It doesn't limit the wait for a response, because `request_timeout` controls the full exchange.
- `tcp_keepalive`: The kernel sends probes on an idle pooled connection. The probes keep NAT and firewall mappings open, and let the kernel find a dead peer before the pool sends a request on the connection. Set this option when connections stay idle in the pool between requests.
- `tcp_user_timeout`: The kernel closes a connection when the peer doesn't acknowledge sent data. This option is available only on Linux. A request to a peer that stopped without notice fails after this timeout, without waiting for `request_timeout`. Acknowledged data isn't affected, so a slow response continues.
- `connection_pool_size`: Sets the maximum number of hosts whose connections are kept open. Increase it if your application calls many different hosts.
- `max_response_size`: Limits the size of HTTP responses to prevent high memory use from unexpectedly large responses. For a compressed response, the limit applies to the decompressed body. For large responses, consider a [payload store](#payload-stores).
- `completion_threads`: Increase this when result delivery does heavy work, such as serialization or encryption, and finished requests wait for a thread. If the value is greater than 1, results are delivered concurrently, so `TaskHandler` callbacks and completion-time observers must be thread-safe. Set it to 1 to deliver results one at a time.
- `completion_retries`: The number of times to retry result delivery before the failure is reported to observers through `completion_failed`. A retry calls `on_complete` or `on_error` again. As a result, a handler that raises an error *after* it enqueues its message delivers that message twice. Make handlers idempotent, or set `completion_retries` to 0 to report the first failure without a retry.
- `shutdown_timeout`: Must be less than the process supervisor's stop timeout, so that in-flight requests and their results finish before a hard kill.

### Response compression

Requests ask for `gzip` compression by default. A completion worker thread decompresses the response body. To change this, set the `accept-encoding` header on a request:

- `identity` turns off compression.
- Any other encoding is delivered still encoded, with its `content-encoding` header, so that you can decode it yourself.

## Sensitive and large payloads

Requests and responses are serialized into your job queue so that they can move between processes. As a result, you need to decide how to keep sensitive values out of the queue, and where to put payloads that are too large for it.

These features cover both cases. They work together:

| Feature | When to use it | How to register it |
| --- | --- | --- |
| [Secrets](#secrets) | A sensitive header or query parameter, such as an API token. | `config.register_secret` |
| [Preprocessors](#request-preprocessors) | A signature calculated from the final request, such as AWS SigV4. | `config.register_preprocessor` |
| [Encryption](#encryption) | The request or response body is sensitive. | `config.encryption_key` |
| [Payload stores](#payload-stores) | Payloads are too large for the queue. | `config.register_payload_store` |

Use secrets and preprocessors first, because they keep sensitive values out of the queue. Use encryption when the payload itself is sensitive, and a payload store when the payload is too large.

### Secrets

If you put an API token directly on a request, the token is written to your job queue. A secret lets you refer to the value by name. The serialized request stores only a marker, `{"$secret" => "name"}`. The processor resolves the value from the configuration when it sends the request.

Register a secret with a value, or with a block that runs each time the secret is resolved:

```ruby
PatientHttp.configure do |config|
  config.register_secret(:authorization, "Bearer #{ENV["API_TOKEN"]}")
  config.register_secret(:api_key) { ENV["MY_API_KEY"] }
end
```

You can also register a secret at the module level. Use this in a library, or in an initializer that loads before the rest of your configuration:

```ruby
PatientHttp.register_secret(:api_key) { ENV["MY_API_KEY"] }
```

Module-level secrets are added to the configuration when it's created, so load order doesn't matter. To check whether a secret is registered, call `PatientHttp.secret_registered?(name)`.

Use a secret reference as a header or query parameter value:

```ruby
PatientHttp.get(
  "https://api.example.com/data",
  callback: MyCallback,
  headers: {"Authorization" => PatientHttp.secret(:authorization)},
  params: {"api_key" => PatientHttp.secret(:api_key), "page" => 2}
)
```

The secret query parameter isn't added to the serialized URL. The other parameters, such as `page`, are added as usual. The processor resolves both secrets immediately before it sends the request. If a secret isn't registered, the request fails with a `PatientHttp::SecretManager::SecretNotFoundError`, which is passed to `on_error`.

### Request preprocessors

A preprocessor changes a request immediately before it's sent, usually to sign it. Signing schemes such as AWS SigV4 calculate values from the final request and set several headers, so a static header value can't express them.

Like secrets, preprocessors are registered in the configuration and referenced by name. The signing code and its credentials stay in the processor and aren't written to the queue.

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

The preprocessor receives a `PatientHttp::OutgoingRequest`. At that time, secret references are resolved, and the `x-request-id` and default `User-Agent` headers are set. The object has these methods:

- `http_method`, `url`, and `body`: Read-only. The URL includes the resolved secret query parameters.
- `headers`: The request headers. You can change them. Names are case insensitive.
- `add_param(name, value)`: Adds a query parameter to the URL, for signing schemes that use query parameters.

To run several preprocessors, pass an array. They run in order, and each one sees the changes of the ones before it. `RequestTemplate` and `request_template` in `RequestHelper` take a `preprocessors:` option as a default. If a preprocessor isn't registered, the request fails with a `PatientHttp::RequestPreparer::PreprocessorNotFoundError`, which is passed to `on_error`.

When a request follows a same-origin redirect, the preprocessors run again for the redirect URL, so signatures stay valid. On a cross-origin redirect, the preprocessors are removed, as are the `Authorization` and `Cookie` headers. As a result, signed credentials aren't sent to another origin.

### Encryption

When the request or response body is sensitive, encrypt it. After you set a key, the integration gems encrypt data before they write it to the queue, and decrypt it when they read it.

The simplest option is `encryption_key`. It uses [ActiveSupport::MessageEncryptor](https://api.rubyonrails.org/classes/ActiveSupport/MessageEncryptor.html) with AES-256-GCM:

```ruby
PatientHttp.configure do |config|
  config.encryption_key = ENV["PATIENT_HTTP_ENCRYPTION_KEY"]
end
```

To rotate keys, pass an array. The first key encrypts data, and all keys are tried for decryption:

```ruby
PatientHttp.configure do |config|
  config.encryption_key = [ENV["PATIENT_HTTP_ENCRYPTION_KEY"], ENV["PATIENT_HTTP_OLD_KEY"]]
end
```

To use another encryption library, provide callables that take and return raw bytes as a String:

```ruby
PatientHttp.configure do |config|
  config.encryption { |bytes| MyEncryption.encrypt(bytes) }
  config.decryption { |bytes| MyEncryption.decrypt(bytes) }
end
```

You can also pass any object that responds to `call`.

Encrypted data is stored as `{"__encrypted__" => true, "value" => "<base64>"}`. The `Encryptor` serializes the original hash to JSON, passes the bytes to your callable, and encodes the result with Base64. A hash without the `"__encrypted__"` key is returned unchanged, so data that was written before you turned on encryption can still be read.

If you write your own `TaskHandler`, see [Build a custom integration](#build-a-custom-integration) for how to add encryption.

### Payload stores

When you register a payload store, any serialized payload larger than `payload_store_threshold` is written to the store instead of the job queue. The queue gets a small reference, which is resolved when the payload is needed. Queue messages stay small, and your application code doesn't change.

```ruby
PatientHttp.configure do |config|
  config.register_payload_store(:redis, adapter: :redis, redis: Redis.new(url: ENV["REDIS_URL"]), ttl: 86_400)
  config.payload_store_threshold = 64 * 1024
end
```

These adapters are available:

| Adapter | Options | Notes |
| --- | --- | --- |
| `:file` | `directory:` | For development and tests only. Hosts don't share the files. |
| `:redis` | `redis:` (required), `ttl:`, `key_prefix:` (default `"patient_http:payloads:"`) | Requires the `redis` gem. The client must respond to `set`, `get`, `del`, and `exists`. |
| `:s3` | `bucket:` (required), `key_prefix:` (default `"patient_http/payloads/"`) | Requires the `aws-sdk-s3` gem. |
| `:active_record` | `model:` | Requires a database table. See the following section. |

The Active Record adapter needs the `patient_http_payloads` table. In a Rails app, load the engine in an initializer, and then install and run the migration:

```ruby
require "patient_http/rails/engine"
```

```bash
bin/rails patient_http:install:migrations
bin/rails db:migrate
```

You can also add the migration yourself:

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

To write your own adapter, subclass `PatientHttp::PayloadStore::Base`, and implement `store_json`, `fetch`, and `delete`. The adapter must be thread-safe.

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
    # Delete the data. Don't raise an error if the key doesn't exist.
  end
end

PatientHttp.configure do |config|
  config.register_payload_store(:custom, adapter: :my_store, **options)
end
```

To move to a new store, register both stores. The last store registered is used for new writes. All registered stores are available for reads.

To store and fetch payloads yourself, use `PatientHttp::ExternalStorage`:

```ruby
storage = PatientHttp::ExternalStorage.new(PatientHttp.configuration)

data = storage.store(response.as_json, max_size: 1024) # Returns the original hash if it's 1KB or smaller.
storage.storage_ref?(data)                             # Returns true if the hash was stored.
storage.fetch(data)                                    # Returns the original hash.
storage.delete(data)                                   # Deletes the stored payload.
```

## Redirects

A redirect response (300, 301, 302, 303, 307, or 308) with a `Location` header is followed automatically, up to `max_redirects` times. A 300 response is followed only when the `Location` header names the server's preferred choice. A redirect loop raises a `RecursiveRedirectError`, and too many redirects raise a `TooManyRedirectsError`. A redirect that isn't followed is passed to the callback as a normal response.

The HTTP method of the redirected request follows RFC 9110:

| Status | Method |
| --- | --- |
| 301, 302 | `POST` changes to `GET`, and the body is removed. Other methods, including `HEAD`, `PUT`, `DELETE`, and `QUERY`, keep their method and body. |
| 303 | `GET` and `HEAD` keep their method. All other methods change to `GET`, and the body is removed. |
| 300, 307, 308 | The method and body don't change. |

The QUERY specification states that the POST-to-GET exception for 301 and 302 doesn't apply to `QUERY`. As a result, a redirected `QUERY` is sent again as a `QUERY` with its body, and a 303 changes it to a `GET`.

### Prevent method changes

To stop following redirects that change the HTTP method, set `follow_method_changing_redirects: false`. For example, a `POST` that gets a 302 then completes with the 302 response, instead of a `GET` to the new location. Redirects that keep the method are still followed, such as a `PUT` that gets a 301, or any method that gets a 307.

You can set the option in the configuration or on a request. If both are set, the request value applies.

```ruby
PatientHttp.configure do |config|
  config.follow_method_changing_redirects = false
end

# Or for one request.
PatientHttp.post(url, callback: MyCallback, body: payload, follow_method_changing_redirects: false)
```

### Remove headers on redirects

The `Authorization` and `Cookie` headers are always removed on cross-origin redirects. To keep other sensitive headers from being sent to a redirect target, list them in `redirect_strip_headers`. Header names are case insensitive. The listed headers are removed from every redirected request, same-origin or cross-origin.

```ruby
PatientHttp.configure do |config|
  config.redirect_strip_headers = ["X-Api-Key", "X-Internal-Token"]
end

# Or for one request. These headers are removed in addition to the configured headers.
PatientHttp.get("https://api.example.com/data", callback: FetchCallback, redirect_strip_headers: "X-Signature")
```

The header names for a request are serialized with it into the job queue, so they apply in the process that follows the redirect.

Only the headers set on the request are removed. Preprocessors run again on each same-origin redirect and can add headers after they're removed. As a result, a header that a preprocessor sets is sent to the redirect target.

When a redirect changes the method and removes the body, the headers that describe the body are removed as well: `Content-Type`, `Content-Length`, `Content-Encoding`, `Content-Language`, and `Content-Location`.

## Response and error objects

`PatientHttp::Response` and the error objects can be serialized to JSON, so they can move through job queues and between processes. Both have `as_json` and `to_json` methods. To create an object from JSON data, use the `load` class method:

```ruby
response = PatientHttp::Response.load(json_data)
error = PatientHttp::Error.load(json_data)
```

A `Response` has the HTTP status code, headers, body, and callback arguments. The error classes, `HttpError`, `RedirectError`, and `RequestError`, have the error message, details about the request, and callback arguments. All error classes are subclasses of `PatientHttp::Error`, and `error.error_type` returns a symbol that identifies the kind of error, such as `:timeout`, `:connection`, or `:http_error`.

Request and response header names are case insensitive. A request header with a `nil` or empty value is never sent. If you set a header to `nil` or `""`, the header is removed, and a header Hash such as `{"X-Header" => nil}` doesn't set the header. A response header that occurs more than one time, such as `set-cookie`, becomes one string with the values joined.

Response bodies are encoded for JSON serialization. Binary content is encoded with Base64. Large text content is compressed with gzip and then encoded with Base64 to reduce the payload size. The `body` and `json` methods of `Response` decode the body for you.

## Troubleshooting

### Warning: `ThreadError: Attempt to unlock a mutex which is not locked`

On some Ruby versions, a warning like this can appear in your logs:

```
warn: Async::Task: Async::Pool::Controller Gardener [...]
    | Task may have ended with unhandled exception.
    |   ThreadError: Attempt to unlock a mutex which is not locked
    |   → .../async-pool-x.y.z/lib/async/pool/controller.rb:132 in `synchronize'
```

The cause is [Ruby bug #20907](https://bugs.ruby-lang.org/issues/20907). For more information, see [socketry/async#424](https://github.com/socketry/async/issues/424). With the fiber scheduler, a fiber that's interrupted while it waits on a `ConditionVariable` doesn't get its mutex again before it exits, which raises a false `ThreadError`. The warning appears when a pooled HTTP client closes while its connection pool's background gardener task is idle. For example, this happens when the pool evicts a connection after a connection error, when the pool is full and evicts the least recently used client, or when the processor shuts down.

The warning is harmless. The connections still close correctly. To remove the warning, upgrade Ruby. The bug is fixed in Ruby 3.2.7 and later, 3.3.7 and later, and 3.4 and later.

## Build a custom integration

This section explains how to integrate the gem with a job system that doesn't have an integration gem. If you use Sidekiq or Solid Queue, the integration gems do all of this for you.

An integration has these parts:

- A `TaskHandler` that delivers results to your job system.
- A `Processor` that runs requests.
- A registered request handler, so that application code can use the `PatientHttp` module methods.

### Create a task handler

The `TaskHandler` connects the processor to your job system:

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
    # Re-enqueue the original job when the processor shuts down before the
    # request finishes.
    MyJobSystem.enqueue_job(@job_id)
  end
end
```

> [!IMPORTANT]
> Task handler callbacks run on the processor's completion worker threads (see `completion_threads`), not on the reactor thread, so they don't block the event loop. Keep them lightweight anyway. Usually, a callback only enqueues a message for another system. Heavy callbacks compete with the reactor for the GVL. A task also counts against capacity until its result is delivered, so slow callbacks reduce request capacity.
>
> Callbacks must be thread-safe. By default, two completion worker threads deliver results concurrently. As a result, two callbacks can run at the same time, in an order unrelated to the order in which the requests finished. To deliver results one at a time, set `completion_threads` to 1.
>
> Callbacks must also be idempotent. A callback that raises an error is retried `completion_retries` times (default 2). If a callback raises an error after it enqueues its message, the message is enqueued again. If that isn't acceptable, set `completion_retries` to 0.

The task handler is responsible for encryption. The base class doesn't encrypt or decrypt data. Use `Configuration#encryptor` each time you serialize data:

```ruby
def on_complete(response, callback)
  encrypted = @configuration.encryptor.encrypt(response.as_json)
  MyJobSystem.enqueue(callback, :on_complete, encrypted)
end
```

Decrypt the data before you create the object again:

```ruby
response = PatientHttp::Response.load(@configuration.encryptor.decrypt(data))
```

### Run a processor

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

If the processor isn't running, `enqueue` raises a `PatientHttp::NotRunningError`. If the processor is at `max_connections`, it raises a `PatientHttp::MaxCapacityError`.

A process can run several named processors, each with its own capacity and threads:

```ruby
PatientHttp::Processor.new(config, name: :llm)
```

A request has an optional `processor` name, which is serialized with the request. Integrations use this name to send the request to a processor.

### Processor lifecycle

```
stopped -> starting -> running -> draining -> stopping -> stopped
```

- `stopped`: The processor doesn't run requests.
- `starting`: The processor starts the reactor thread.
- `running`: The processor accepts and runs requests.
- `draining`: The processor rejects new requests and finishes in-flight requests.
- `stopping`: The processor shuts down and re-enqueues requests that didn't finish.

```ruby
processor.start              # Start the processor.
processor.running?           # => true

processor.drain              # Stop accepting new requests.
processor.draining?          # => true

processor.stop(timeout: 25)  # Shut down gracefully.
processor.stopped?           # => true
```

When the processor stops with in-flight requests, it calls `TaskHandler#retry` for each request that didn't finish, so that the job system can enqueue it again.

### Observe the processor

To receive processor events, subclass `PatientHttp::ProcessorObserver`, and override the methods for the events that you need:

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

Observers can also track each task through the processor:

- `request_enqueued(request_task)`: Runs when a task is given to the processor, before the reactor can see it. This method always runs before `request_start`. As a result, observers can set up durable tracking, such as a crash-recovery registry entry, before `Processor#enqueue` returns or raises an error.
- `request_rejected(request_task)`: Runs when the processor doesn't accept a task, because it isn't running or is at capacity. Remove anything that `request_enqueued` set up.
- `request_requeued(request_task)`: Runs when a task that didn't finish is re-enqueued through its task handler, because the processor shut down or the reactor failed. After this call, the job system owns the request again.
- `completion_failed(request_task, error)`: Runs when a result can't be delivered after all retries. `request_end` doesn't run in this case, so durable tracking stays in place for external recovery.

To get the IDs of all queued, pending, and in-flight tasks, call `Processor#tracked_request_ids`. For example, use it to update heartbeats for tasks that haven't started yet.

For the thread that runs each observer method, see the `ProcessorObserver` documentation. Observers must be thread-safe.

### Register a request handler

To let application code use the `PatientHttp` module methods, register a request handler. The handler builds each task:

```ruby
PatientHttp.register_handler do |request:, callback:, callback_args: nil, raise_error_responses: nil|
  task = PatientHttp::RequestTask.new(
    request: request,
    task_handler: MyTaskHandler.new(MyJobSystem.current_job_id),
    callback: callback,
    callback_args: callback_args,
    raise_error_responses: raise_error_responses
  )
  processor.enqueue(task)
  task.id
end
```

To raise an error if a handler is already registered, use `PatientHttp.register_handler!`. To check whether a handler is registered, call `PatientHttp.handler_registered?`.

To make `PatientHttp.configure` yield your own configuration class, register the integration as the configuration provider. The provider must respond to `new_configuration`, which returns a new configuration, and to `configure`:

```ruby
PatientHttp.register_configuration_provider(MyIntegration)
```

### Test an integration

To test integration code without the async processor, use `SynchronousExecutor`. It runs a request on the calling thread, runs the optional hooks, and then calls the callback service:

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

Most applications need only the integration gem for their job system, which depends on this gem:

```ruby
gem "patient_http-sidekiq"
# or
gem "patient_http-solid_queue"
```

To use this gem on its own, add it to your Gemfile:

```ruby
gem "patient_http"
```

Then install it:

```bash
bundle install
```

## Contributing

Open a pull request on [GitHub](https://github.com/bdurand/patient_http).

Follow the [standardrb](https://github.com/testdouble/standard) style, and run `standardrb --fix` before you submit a pull request.

Run the tests:

```bash
bundle exec rspec
```

The [patient_http-sidekiq](https://github.com/bdurand/patient_http-sidekiq) and [patient_http-solid_queue](https://github.com/bdurand/patient_http-solid_queue) gems each have a test app for integration testing.

## Further reading

- [Architecture](ARCHITECTURE.md)

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
