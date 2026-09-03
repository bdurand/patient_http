# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.6.0

### Added

- `Configuration#redirect_downgrade` and `Request#redirect_downgrade` (default true): when false, a redirect that would change the HTTP method (such as POST to GET on a 301, 302, or 303) is not followed and the redirect response is delivered to the callback instead. Redirects that preserve the method are still followed. The request setting overrides the configuration.
- `Configuration#redirect_strip_headers` and `Request#redirect_strip_headers`: header names (matched case insensitively) that are always removed from redirected requests, so sensitive headers are never sent to a redirect target. Request-level names are applied in addition to the configured ones and survive serialization.
- `PatientHttp.request`, `RequestHelper#async_request`, and `RequestTemplate#request` (and their `get`, `post`, and other method helpers) accept `redirect_downgrade:` and `redirect_strip_headers:` and pass them to the `Request`.
- `HEAD` and `QUERY` HTTP methods are supported by `Request`, `RequestTemplate`, `RequestHelper` (`async_head`, `async_query`), and `PatientHttp.head` / `PatientHttp.query`. `HEAD` requests cannot carry a body. The response size limit is not applied to the `Content-Length` of a `HEAD` response because no body is transferred.

### Changed

- The HTTP method used when following a redirect now follows RFC 9110. On 301 and 302 responses only `POST` is changed to `GET`; `HEAD`, `PUT`, `PATCH`, `DELETE`, and `QUERY` are re-sent unchanged with their body. On 303 responses `GET` and `HEAD` are preserved and every other method becomes `GET`. Previously every method was changed to `GET` on 301, 302, and 303.
- When a redirect changes the method and drops the body, the `Content-Type`, `Content-Length`, `Content-Encoding`, `Content-Language`, and `Content-Location` headers are removed from the redirected request as well.
- A 300 Multiple Choices response with a `Location` header is now followed, preserving the method and body. A 300 response without `Location` is delivered as a response, as before.
- `RequestTask#redirect_task` accepts a `strip_headers:` option with the configured header names to remove.

## 1.5.0

### Added

- Completion executor: finished results are now delivered on a small pool of worker threads (`Configuration#completion_threads`, default 2, minimum 1) instead of the reactor thread. Response decoding, payload encoding, task-handler callbacks, and `request_end` observers all run on these threads, so the reactor only performs socket I/O and light bookkeeping.
- `Configuration#completion_retries` (default 2): delivery of a finished result is retried with a short backoff before the failure is reported. A retry calls `on_complete`/`on_error` again, so handlers must be idempotent; set `completion_retries: 0` to report the first failure without retrying.
- `ProcessorObserver#completion_failed(request_task, error)`: sent when a result could not be delivered after all retries. `request_end` is NOT sent in this case, so durable tracking (crash-recovery records) stays in place and the request can be recovered by an external process instead of being silently lost. This replaces the previous behavior where a delivery failure was logged, swallowed, and the tracking was torn down.
- `Configuration#max_connections_per_host` (default nil = unlimited): bounds the number of connections each host's HTTP client may open, which bounds file descriptor usage.
- `Processor#remaining_capacity` and `Processor#capacity_available?`: cheap, advisory capacity checks with no observer notifications, so integrations can reject work before paying registration costs.
- Named processors: `Processor.new(config, name:)` names a processor (used in its thread names), and `Request` accepts a `processor:` option that survives serialization (`as_json` / `load`), so integrations can route requests to one of several processors in the same process. `RequestTemplate`, `RequestHelper`, and `PatientHttp.request` pass the option through. `PatientHttp::UnknownProcessorError` is defined for handlers to raise for unrecognized names. Serialized output for requests without a processor name is unchanged.

### Changed

- Compressed response bodies (gzip/deflate) are now inflated on a completion worker thread instead of the reactor thread. The size limit still applies to the inflated bytes, so gzip-bomb protection is unchanged. The `content-encoding` header is removed from the response after decoding, as before.
- Requests send `accept-encoding: gzip` by default, but a request that sets the header keeps its own value. Set `accept-encoding: identity` on a request to opt out of compression, or name another encoding to receive the body still encoded. Previously the header was set unconditionally.
- Inline and synchronous execution decodes response bodies through the same reader as the async path instead of a `Protocol::HTTP::AcceptEncoding` middleware. The middleware overwrote the request's `accept-encoding` header, so a request opting out of compression was previously honored only when it ran on the processor.
- A `content-encoding` header naming more than one encoding is now decoded from the outermost encoding inward, and `identity` is recognized. Previously only a header holding exactly one supported name was decoded, so a value such as `gzip, identity` delivered the body still compressed.
- A response body carrying an encoding the reader cannot decode is delivered unchanged with a `content-encoding` header naming only the encodings still applied, and the condition is now logged as a warning. Such a body keeps its binary encoding, because the Content-Type charset does not describe encoded bytes.
- `ProcessorObserver` hooks no longer all run on the reactor thread; see the class documentation for the thread each hook runs on. `request_end` and `request_error` for completed requests now run on completion worker threads.
- **Breaking for callbacks:** `TaskHandler` callbacks and completion-time observer hooks must now be thread-safe. The reactor thread previously serialized them; they now run concurrently on `completion_threads` workers, in an order unrelated to the order the requests completed. Set `completion_threads: 1` to restore serialized delivery.
- On shutdown, results that were already handed off for delivery are delivered before remaining tasks are re-enqueued.

### Fixed

- A `deflate` response body carrying a zlib header, which is the format RFC 9110 specifies for that encoding, failed to inflate with `Zlib::DataError: invalid stored block lengths`. Both the zlib and the raw deflate wire formats are now supported.
- A response body that a text content type claims is text, but that does not hold text, is now stored as a binary payload instead of as text. Such a body could not be serialized, so `JSON.generate` raised `JSON::GeneratorError` and the result could never be delivered. This happened for a body still carrying a content encoding the reader cannot decode (for example `br`), and for text holding an invalid byte sequence.

## 1.4.0

### Added

 - `ProcessorObserver` events for the full task pipeline: `request_enqueued` is sent when a task is announced to the processor, before the task is visible to the reactor, so observers can set up durable tracking (e.g. a crash-recovery registry entry) before `Processor#enqueue` returns or raises. `request_rejected` is sent when an announced task is not accepted (not running or at capacity). `request_requeued` is sent when an incomplete task is re-enqueued through its task handler, so observers can tear down tracking for tasks the job system owns again. Redirect tasks are announced with `request_enqueued` as well.
 - `Processor#tracked_request_ids` returns the IDs of all tasks in the pipeline (queued, pending, and in-flight), so durable tracking can keep heartbeats alive for tasks that have not started yet.

### Fixed

- A task is now marked as started before the `request_start` notification is sent. Before this fix, a shutdown that snapshotted the task between the two steps re-enqueued the task without a `request_end` notification, which could leak observer tracking for the task and cause a duplicate execution through crash recovery.

## 1.3.0

### Added

- `PatientHttp.inline!` registers a request handler that executes requests inline (synchronously, in-process) through `SynchronousExecutor`, for consoles, tests, and development environments with no job-system integration. `PatientHttp.inline?` checks whether the inline handler is currently registered, and `PatientHttp.execute_inline` executes a single request inline without registering a handler.
- `PatientHttp.register_secret` registers named secrets at the module level, independent of any `Configuration`. Module-level secrets are applied to the new `PatientHttp.default_configuration` (immediately if set, or when it is set later), making registration order between application code and integration gem configuration irrelevant. `PatientHttp.secret_registered?` checks whether a secret is registered at the module level or on the default configuration.
- `PatientHttp::RequestHelper`'s `request_template` and `async_request` now accept `preprocessors:`, matching `PatientHttp.request` and `RequestTemplate`.
- `PatientHttp.handler_registered?` checks whether a request handler is registered.

## 1.2.0

### Added

- Request preprocessors for modifying the outgoing request just before it is sent — most usefully, to sign requests (e.g. AWS SigV4 signatures that must set multiple headers computed over the final request). Register a preprocessor on the `Configuration` with `register_preprocessor(name)` and attach it to a request with `preprocessors: name`. The request serializes only the preprocessor name; the callable (and any credentials it uses) stays on the processor side. Preprocessors receive an `OutgoingRequest` — a view of the request after secret resolution with read access to the method, URL, and body, mutable headers, and an `add_param` method for appending query parameters. On redirects, preprocessors re-run against each redirect URL and are dropped on cross-origin hops, consistent with sensitive header stripping.

### Fixed

- `SynchronousExecutor` no longer resolves secret query params twice per request, which previously invoked callable secrets twice.
- Graceful shutdown now works as documented: requests that complete while the processor is stopping have their responses delivered instead of being discarded and retried, and `Processor#stop` returns as soon as in-flight requests finish rather than always blocking for the full `shutdown_timeout`.
- `Processor#stop` performs a second re-enqueue pass after the reactor thread exits, closing a race where a task dequeued but not yet tracked at shutdown could be silently lost.
- Task results are now claimed atomically at shutdown so a completing request can no longer trigger both its completion callback and a `TaskHandler#retry` for the same task.
- `Processor#start` on a draining processor is now a no-op instead of spawning a second reactor thread that shared the queue and connection pools with the draining one.
- The processor can no longer end up in a running state with a dead reactor thread when the reactor fails during startup.
- Processor observers are now invoked outside of internal locks, so an observer callback can safely call back into processor methods such as `total_count` without raising a recursive locking error.
- `SynchronousExecutor` no longer invokes the error callback twice when a redirect fails with too many redirects or a redirect loop.
- `HttpHeaders#merge` no longer mutates the receiver. This also fixes `RequestTemplate` permanently absorbing per-request headers into its defaults, which could leak headers (including credentials) across requests built from the same template.
- `Request` now copies headers passed to its constructor instead of holding (and potentially mutating) the caller's `HttpHeaders` instance.
- `Errno::ETIMEDOUT` is now treated as a connection error, evicting the pooled client and classifying the `RequestError` as `:connection`.
- `RedirectError.load` validates that the serialized error class is a `RedirectError` subclass instead of instantiating an arbitrary class name from the payload.
- Fixed the Redis payload store documentation to use the `redis` gem interface (`Redis.new`); the previously documented `RedisClient` does not respond to the methods the store calls.

## 1.1.2

### Added

- Added `protocol` configuration option to force the HTTP protocol to `:http1` or `:http2` instead of negotiating with the server. Forcing `:http1` also limits the TLS ALPN advertisement to `http/1.1`, which can work around SSL-intercepting proxies that mishandle HTTP/2 negotiation.

### Fixed

- `Errno::ECONNABORTED` ("Software caused connection abort") is now treated as a connection error: the pooled client for the host is evicted so the aborted connection is not reused, and `RequestError` classifies it as `:connection` instead of `:unknown`. This error is commonly raised when an SSL-intercepting proxy kills a connection.

## 1.1.1

### Fixed

- Connection pools are now closed gracefully inside the reactor during shutdown. Previously the reactor stopped with open pools, causing async-pool to force-cancel each connection pool's background gardener task mid-wait and emit a noisy (but harmless) `ThreadError: Attempt to unlock a mutex which is not locked` warning when the process was killed.

## 1.1.0

### Added

- Secret manager for referencing sensitive headers and query parameters indirectly. Register secrets on the `Configuration` with `register_secret` (static value or lazy block), then reference them when building a request via `PatientHttp.secret(name)`. The serialized request stores only a `{"$secret" => name}` reference; the value is resolved by the processor when the request is sent, keeping sensitive values out of the job queue and logs.

## 1.0.0

### Added

- Async HTTP processor that runs in a dedicated thread with a Fiber-based reactor, allowing hundreds of concurrent HTTP requests without blocking application threads.
- Pluggable `TaskHandler` interface for integrating with any job system or application framework.
- Callback system with `on_complete` and `on_error` handlers for processing HTTP responses and errors.
- `Request` and `RequestTemplate` classes for building HTTP requests with support for all HTTP methods (GET, POST, PUT, PATCH, DELETE).
- `RequestTemplate` for repeated requests to the same API with shared configuration (base URL, headers, timeouts).
- JSON-serializable `Response` and error objects for safe passing through job queues and across process boundaries.
- Automatic redirect following with configurable maximum redirects.
- HTTP/2 support via the async-http gem.
- Connection pooling with configurable pool size for efficient reuse of connections across hosts.
- External payload storage system with adapters for File, Redis, and S3 to handle large request/response payloads.
- Configurable response size limits to bound memory usage.
- Proxy support for HTTP/HTTPS proxies with authentication.
- Automatic retry support for failed requests.
- Graceful shutdown with configurable timeout and automatic retry of incomplete requests via `TaskHandler#retry`.
- `ProcessorObserver` interface for monitoring processor events (request start/end, errors, capacity exceeded).
- `SynchronousExecutor` for testing without starting the async processor.
- Configurable connection limits, timeouts, response size limits, and User-Agent headers.
- Typed error classes (`HttpError`, `ClientError`, `ServerError`, `RedirectError`, `RequestError`) for precise error handling.
- Optional treatment of non-2xx HTTP responses as errors via `raise_error_responses` configuration.
- `CallbackArgs` for passing custom data through the request/response cycle.
