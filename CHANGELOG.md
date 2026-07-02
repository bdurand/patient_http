# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 1.2.0

### Added

- Request preprocessors for modifying the outgoing request just before it is sent — most usefully, to sign requests (e.g. AWS SigV4 signatures that must set multiple headers computed over the final request). Register a preprocessor on the `Configuration` with `register_preprocessor(name)` and attach it to a request with `preprocessors: name`. The request serializes only the preprocessor name; the callable (and any credentials it uses) stays on the processor side. Preprocessors receive an `OutgoingRequest` — a view of the request after secret resolution with read access to the method, URL, and body, mutable headers, and an `add_param` method for appending query parameters. On redirects, preprocessors re-run against each redirect URL and are dropped on cross-origin hops, consistent with sensitive header stripping.

### Fixed

- `SynchronousExecutor` no longer resolves secret query params twice per request, which previously invoked callable secrets twice.

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
