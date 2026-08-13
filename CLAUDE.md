# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Run all tests
flutter test

# Run a single test file
flutter test test/api_call_test.dart

# Lint
flutter analyze

# Format — run before committing; `--set-exit-if-changed` to check without writing
dart format lib/ test/

# Get dependencies
flutter pub get
```

## Architecture

`baaba_api_handler` is a Flutter package (not an app) that wraps Dio into a typed, functional HTTP client. It is published and consumed by other projects — the public surface in `ts_api_handler.dart` is the contract.

### Public surface

Two identical entrypoints: `lib/baaba_api_handler.dart` (conventional) and `lib/ts_api_handler.dart` (predates the rename, still the canonical file). A third, `lib/testing.dart`, ships `FakeApiServices` for consumers' tests and is never imported by production code.

Exports: `ApiServices`, `ApiConfig`, `AuthConfig`, `CachePolicy`, `RetryPolicy`, `ApiObserver`, `ApiLogOptions`, `Base64LogTrimmer`, `ApiCacheHelper`, `UploadFile`, `Failure`, `ErrorSource`, `ResponseCode`, `HttpMethod`, `listParser`, the `CachedResponse` extension, plus pass-throughs `Either`/`Left`/`Right` (fpdart), `Response`/`CancelToken`/`FormData`/`MultipartFile`/`RequestOptions` (Dio), and `APICacheDBModel`.

Current version: **2.0.0**

### Configuration

Everything lives on one `ApiConfig` object passed to `ApiServices.init(...)`. This replaced four separate static mutables in 2.0.0 — with nine features to configure, a setter per feature meant a dozen statics with load-order footguns.

`ApiServices` holds `_config` (the whole `ApiConfig`), `_instance`, and the two loader callbacks as statics. `configure()`, `setConnectivityCheck()`, and `setLogging()` remain as `@Deprecated` forwarders that build an `ApiConfig` and call `init()`; they are removed in 3.0.0.

**Which settings apply when.** Anything read at request time — `bypassConnectivityCheck`, `isSuccess`, `observer` — takes effect immediately because the implementation reads `ApiServices._config` per call. Anything baked into the Dio client — `baseUrl`, timeouts, `logging`, `retry`, `auth`, `httpClientAdapter` — applies only to the client built by that `init()` call.

`ApiServices.reset()` clears the singleton, config, and loader callbacks. Tests should call it in `tearDown`.

### Request lifecycle

```
ApiServices.instance().get/post/put/patch/delete/upload/download(...)
  → _sendRequest    — loader accounting, cache policy (read-before, write-after)
  → _dispatch       — in-flight de-duplication
  → _performRequest — connectivity check, Dio call, outcome reporting
      Dio interceptor chain, order fixed in DioFactory.getDio():
        1. TokenRefreshInterceptor  — attaches token; refreshes and replays on 401
        2. NetworkRetryInterceptor  — retries transient failures and retryable statuses
        3. PrettyDioLogger          — non-release builds only
        4. ObserverInterceptor      — onRequest only (see below)
  → ErrorHandler.handle()  — DioException → Failure
  → Right(Response) or Left(Failure)
  → _parse<T>()     — only for the *As<T> variants
```

All methods return `Either<Failure, Response>` (fpdart), or `Either<Failure, T>` for the `*As<T>` variants. No exceptions cross the API boundary.

The three-layer split in `api_service.dart` matters: the loader must be reference-counted per *caller* (outermost), de-duplication must sit above the network call but below the cache, and the connectivity check must be inside the deduped call so two collapsed callers share one probe.

### Typed responses

`getAs<T>`/`postAs<T>`/`putAs<T>`/`patchAs<T>`/`deleteAs<T>` take a `parser` and route through the untyped sibling, then `_parse<T>`. A throwing parser becomes `Failure(ErrorSource.parseError, ...)` carrying the raw body in `data` — never rethrown.

`listParser(fromJson, {key})` is a top-level helper returning a `List<T> Function(dynamic)`, so list endpoints don't need five more methods on the interface.

### Error model

`ErrorHandler` converts `DioException` → `ResponseCode` (enum with inline integer raw values, negative for non-HTTP errors) → `ErrorSource` (semantic enum) → `Failure` (Equatable, with `errorType`, `code`, `message`, `data`, `statusCode`).

`Failure.data` holds the raw response body and `statusCode` the literal HTTP status — `code` collapses anything unrecognised to `defaultError`, so `statusCode` is the field to read for the real status. `Failure.validationErrors` parses a `{"errors": {field: [...]}}` body.

Message extraction lives in `src/utils/error_body.dart` (`extractErrorMessage`), shared by `ErrorHandler` and the `isSuccess` path so both surface the same message for the same body. It tries `message`, `detail`, then `error`, follows one level into a nested object, and joins a list.

`ResponseCode` internal codes: `connectTimeout(-1)`, `cancel(-2)`, `receiveTimeout(-3)`, `sendTimeout(-4)`, `cacheError(-5)`, `noInternetConnection(-6)`, `defaultError(-7)`, `connectionFailure(-8)`, `parseError(-9)`.

> Adding a variant to `ErrorSource` or `ResponseCode` is a **breaking change** — consumers switching exhaustively stop compiling. `parseError` is why 2.0.0 is a major.

### Connectivity check

`NetworkInfo` runs a pre-flight probe before every request unless `bypassConnectivityCheck` is set. The probe is a real network round-trip, so a **positive** result is cached for `connectivityCacheTtl` (default 5s) and concurrent callers share one in-flight probe.

**Negative results are deliberately never cached.** A cached `false` would keep reporting offline for seconds after the connection came back — exactly when the user is hammering retry. `probe` and `clock` are injectable so tests need neither network nor sleeps.

### Token refresh (`src/interceptors/token_refresh_interceptor.dart`)

Unchanged in 2.0.0 apart from a `fromConfig` factory taking `AuthConfig`. The original multi-parameter constructor is kept because the test suite drives it directly.

On 401: checks `extra['_tokenRetried']` against loops; guards concurrent refreshes with `_isRefreshing` + `Completer<bool>` so a burst of 401s all succeed off one refresh; calls `onTokenRefresh()`, then `getToken()`, rebuilds headers, replays. `onRefreshFailed()` fires if refresh fails.

`refreshTimeout` bounds the wait for the pathological case where the refresh endpoint itself 401s — that inner call is queued behind the very refresh it's part of.

### Retries (`src/config/retry_policy.dart`)

Two things get retried, and the idempotency rule differs between them:

- **Transport errors** (connect/receive/send timeout, connection error) — idempotent methods only (`GET`/`HEAD`/`OPTIONS`/`PUT`/`DELETE`). A `POST` may already have been processed before the timeout.
- **Status codes** in `retryableStatusCodes`. `429` and `503` are in `alwaysRetryableStatusCodes` and retry for *any* method, because the server explicitly said it did not process the request. `408`/`500`/`502`/`504` are ambiguous and stay gated on idempotency.

`retryIf` is the final veto. `Retry-After` is honoured in both delta-seconds and HTTP-date forms, clamped to `maxDelay`, and beats the computed backoff. Backoff is exponential with full jitter (`random(0, computedDelay)`), replacing 1.x's linear interval which made concurrent failures retry in lockstep. `Random` is injectable for deterministic tests.

`src/utils/http_date.dart` exists because `dart:io`'s `HttpDate` would make the package unusable on web.

### Caching

`ApiCacheHelper` wraps `APICacheManager` (SQLite). Key prefix is `api_cache_`.

Two hazards in `APICacheManager`, both worked around in `ApiCacheHelperImplementation`:

> **`getCacheData` calls `.first` on an empty query result, so it throws `StateError` on a miss.** Catching that *is* the miss check. Do not "improve" it by guarding with `isAPICacheKeyExist` first: that returns `rows.length == 1`, so it answers false for a duplicated key exactly as it does for a missing one, turning a recoverable state into a permanent miss. `.first` handles duplicates fine.

> **`addCacheData` is check-then-act with no transaction** — it asks `isAPICacheKeyExist`, then inserts or updates. Two concurrent writes for one key both see "absent" and both insert, and the resulting duplicate rows are not self-correcting: `isAPICacheKeyExist` then reports the key missing forever while every further write adds another row. De-duplication makes this the *ordinary* path, since two collapsed callers each write the response. `setCacheData` therefore chains writes per key through `_pendingWrites`.

`CachePolicy` is opt-in per request on `get`/`getAs` only — a cache policy on a `POST` is meaningless and deliberately not expressible. `networkOnly` (default) is the 1.x behaviour.

`cachePolicy` is **nullable** on the public methods so "not specified" is distinguishable from "explicitly networkOnly". `_effectiveCachePolicy` resolves it: `ApiConfig.cacheEnabled: false` wins over everything, then the call site's value, then `ApiConfig.defaultCachePolicy`. The `_cache` getter is only touched when the resolved policy is not `networkOnly`, so `cacheEnabled: false` genuinely never opens SQLite.

Keys come from `src/utils/cache_key.dart` and include sorted query parameters — 1.x used the raw url, so `?page=1` and `?page=2` collided. Keys are **not** hashed: a digest would have to be stable across app restarts, and `String.hashCode` isn't.

Cached responses are stored as `jsonEncode(response.data)` and rebuilt into a `Response` with `extra[fromCacheKey] = true`, readable via `response.isFromCache`. Only 2xx is stored, and writes are best-effort — a body that won't encode is skipped rather than failing the request.

Entries are **not** scoped per user; `clearAllCache()` on logout is the documented contract.

### De-duplication

`_inFlight: Map<String, Future<...>>` on `ApiServicesImplementation`, keyed by method + canonical url + body. Only the originator stores and removes the entry; followers just await it.

Skipped when the caller supplies a `CancelToken` — sharing one network call would let either caller cancel the other's request. GET-only, opt out with `dedupe: false`.

### Observer

`ApiObserver.onRequest` comes from `ObserverInterceptor`; **`onResponse` and `onFailure` are reported from `ApiServicesImplementation`, not from Dio events.** This is deliberate: `TokenRefreshInterceptor` resolves a recovered 401 with `handler.resolve(...)`, which skips the rest of the chain, so an interceptor-based observer would miss every refreshed success and would also see intermediate failures the package went on to recover from. Reporting from the service layer covers offline short-circuits, parse errors, and `isSuccess` rejections that Dio never produces an exception for.

> **Notification happens in exactly one place: `_notify`, called from `_sendRequest`** — the outermost layer, which runs once per *caller*. It must not move deeper. `_dispatch` and `_performRequest` are shared: de-duplication collapses two callers onto one `_performRequest`, so notifying from there emits one event for two calls. Cache hits, resolved in `_resolve`, would meanwhile still fire per caller — the inconsistency this layering exists to prevent. `download()` and `upload()`'s file-read failure bypass `_sendRequest` and call `_notify` themselves.

Inner layers therefore return failures without reporting them; they attach `Failure.requestOptions` (via `withRequest`) so `_notify` can pass the request along. `requestOptions` is excluded from `props` — `RequestOptions` has no value equality, so including it would make every real failure unequal to every other.

A `*As<T>` parse failure fires **both** `onResponse` (the HTTP call succeeded) and `onFailure` (the body could not be understood). Two real events; `_parse` runs per caller so it needs no special handling.

Every observer callback is wrapped in try/catch — a broken observer must never break a request.

### Request cancellation

`_activeTokens: Set<CancelToken>` tracks every active token; `cancelRequest()` cancels all of them. Tokens are removed in the `finally` of `_performRequest`/`download`.

### Loading indicator

`ApiServices.configureLoader({onShow, onHide})`. Reference-counted via `ApiServices._activeLoadingCount` so concurrent requests share one indicator. The counter is **static**, matching the scope of the callbacks it drives — the indicator is one global widget, and a second `init()` while requests are in flight would otherwise start a fresh per-instance count against a dialog the previous client is still driving. `reset()` clears it. `_sendRequest` wraps its whole body in try/finally, so the loader hides on success, `Failure`, and thrown exceptions alike. `upload()` holds the loader across file reads *and* the request, passing `showLoader: false` down to `_sendRequest` to avoid double-counting.

### Uploads

`upload()` builds `FormData` from `fields` + `List<UploadFile>`. `UploadFile.fromPath` for mobile/desktop, `fromBytes` for web.

> `_headersFor` strips a JSON `content-type` when the body is `FormData` — from caller-supplied headers too, not just the default set. Sending it would replace the `multipart/form-data` type Dio generates, boundary included, and the server would reject the upload. An explicit `multipart/*` value is left alone.

> **Both replay paths must call `prepareForReplay` before `dio.fetch`.** `FormData.finalize()` throws `StateError` on a second read, and two paths replay a request: `NetworkRetryInterceptor` (a `429`/`503` bypasses the idempotency check, so an upload *is* retried) and `TokenRefreshInterceptor` (a `401` on an upload long enough to outlive its token). `prepareForReplay` swaps in `FormData.clone()`, which rebuilds from the same stream factory so a file part re-opens from disk. Without it both paths throw instead of retrying — silently, since `StateError` is not a `DioException`.

### Logging

`PrettyDioLogger` is attached only when `!kReleaseMode && config.logging.enabled`. `ApiLogOptions` mirrors `PrettyDioLogger`'s constructor rather than exposing it, so the logging library can be swapped without a breaking change. `filter` is intentionally not mirrored — its callback takes `FilterArgs`, which would leak the package type.

**`logPrint` is a sink, not a switch.** Every line the logger produces passes through it, which makes it the extension point for rewriting the stream. `ApiLogOptions.trimBase64` uses it: `DioFactory._logSink` wraps the caller's sink in a `Base64LogTrimmer` (a fresh one per client — it holds a running count of elided characters), so a custom `logPrint` still receives every line, already trimmed.

> `Base64LogTrimmer` filters **lines, not fields** — the logger has already flattened the body by the time it is called, so the test is a shape test: a run of the base64 alphabet at least `minRunLength` long. Continuation lines are swallowed and counted; the first line of a blob keeps its key plus `keptChars` of value. This is why it is coupled to PrettyDioLogger's box-drawing gutter (`_gutter` strips `║╟╔╚╝═`) — **replacing the logging library breaks it silently**, with no error, just the base64 flooding back. Any logger swap must keep the same line framing or ship a matching trimmer.

### Testing notes

- `sqflite_common_ffi` initialises an in-process SQLite for cache tests — `sqfliteFfiInit()` in `setUpAll`.
- `mocktail` for all mocks. Mocks created in `setUpAll` are shared across a group; `reset(mock)` in `setUp` if you need `verifyNever`.
- Two established patterns: **`MockDio` + `MockNetworkInfo`** for service-level tests, and a **fake `HttpClientAdapter`** for interceptor-level tests that drive real Dio end-to-end. Don't invent a third.
- `ApiServices.reset()` in `tearDown` for anything touching static config.
- Network-level tests mock `Dio` directly; don't mock `ApiServices` itself — use `FakeApiServices` from `lib/testing.dart`.

#### Local environment note

`sqlite3` builds a native asset by downloading a prebuilt DLL. On a network where Dart's TLS trust store fails (Windows dynamic cert loading, dartbug.com/52266), that download fails and blocks the **entire** test run, not just the cache tests. Workaround: fetch the DLL with PowerShell and drop it in the hook's build cache, which reuses any file whose SHA-256 matches:

```powershell
Invoke-WebRequest https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.4.0/sqlite3.x64.windows.dll -OutFile "$env:TEMP\sqlite3.dll"
Copy-Item "$env:TEMP\sqlite3.dll" ".dart_tool\hooks_runner\shared\sqlite3\build\download-<hash-prefix>\sqlite3.dll"
```

The expected hashes are in `sqlite3/lib/src/hook/asset_hashes.dart` in the pub cache; the directory name is the first 8 characters of the matching hash.
