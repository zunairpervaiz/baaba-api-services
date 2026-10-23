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

# Format — run before committing; `--set-exit-if-changed` to check without writing.
# The SDK floor is 3.8, so this is the "tall" formatter style (trailing commas are managed by the tool).
dart format lib/ test/ example/

# Get dependencies
flutter pub get
```

## Architecture

`baaba_api_handler` is a Flutter package (not an app) that wraps Dio into a typed, functional HTTP client. It is published and consumed by other projects — the public surface in `ts_api_handler.dart` is the contract.

### Public surface

Two identical entrypoints: `lib/baaba_api_handler.dart` (conventional) and `lib/ts_api_handler.dart` (predates the rename, still the canonical file). A third, `lib/testing.dart`, ships `FakeApiServices` for consumers' tests and is never imported by production code.

Exports: `ApiServices`, `ApiConfig`, `AuthConfig`, `RetryPolicy`, `ApiObserver`, `ApiLogOptions`, `Base64LogTrimmer`, `UploadFile`, `Failure`, `ErrorSource`, `ResponseCode`, `HttpMethod`/`HttpMethodExtension`, `listParser`, plus pass-throughs `Either`/`Left`/`Right` (fpdart), `Response`/`CancelToken`/`FormData`/`MultipartFile`/`RequestOptions`/`ResponseType` (Dio).

Current version: **4.0.0**. Latest on pub.dev is **2.0.0** — 3.0.0 and 3.1.0 were never published, so 4.0.0 is the next release there and its CHANGELOG/MIGRATION entries must stay readable for someone jumping straight from 2.0.0. Until 4.0.0 is published, new changes go into the 4.0.0 section rather than a new version. SDK floor: Dart 3.8 / Flutter 3.32 — the oldest the dev tooling (`flutter_lints` 6) can actually build, so the constraint never claims more than is tested.

Response caching (`CachePolicy`, `ApiCacheHelper`, the `api_cache_manager`/SQLite dependency) was removed in 4.0.0. Don't reintroduce a persistence dependency without discussing it — the package deliberately persists nothing.

### Configuration

Everything lives on one `ApiConfig` object passed to `ApiServices.init(...)`. This replaced four separate static mutables in 2.0.0 — with nine features to configure, a setter per feature meant a dozen statics with load-order footguns.

`ApiServices` holds `_config` (the whole `ApiConfig`), `_instance`, and the two loader callbacks as statics. The 1.x setters (`configure()`, `setConnectivityCheck()`, `setLogging()`) were deprecated in 2.0.0 and removed in 3.0.0; `init()` is the only way to configure.

**Which settings apply when.** Anything read at request time — `bypassConnectivityCheck`, `isSuccess`, `onRejected`, `observer` — takes effect immediately because the implementation reads `ApiServices._config` per call. Anything baked into the Dio client or the `NetworkInfo` — `baseUrl`, timeouts, `logging`, `retry`, `auth`, `httpClientAdapter`, `connectivityProbe`, `connectivityCacheTtl` — applies only to the client built by that `init()` call.

A throwing `isSuccess` counts as a rejection (fails closed, via `_accepts`). It is not applied to `head()` or `download()` — neither has a body to judge, so a body-reading predicate would reject every call; `FakeApiServices` skips them too (`evaluate: false`). `isSuccess` rejections route through `onRejected` first, which may return a `Failure` of its own; `null` or a throwing builder falls back to the generic `badRequest`.

`ApiServices.reset()` clears the singleton, config, and loader callbacks, and cancels the old client's in-flight requests — otherwise one finishing after a logout still carries the previous user's token and reports to their observer. `init()` deliberately does not cancel. Tests should call it in `tearDown`.

### Request lifecycle

```
ApiServices.instance().get/post/put/patch/delete/upload/download(...)
  → _sendRequest    — loader accounting, observer notification
  → _dispatch       — in-flight de-duplication
  → _performRequest — connectivity check, Dio call, outcome reporting
      Dio interceptor chain, order fixed in DioFactory.getDio():
        1. TokenRefreshInterceptor  — attaches token; refreshes and replays on 401
        2. ApiConfig.interceptors   — the caller's own, if any
        3. NetworkRetryInterceptor  — retries transient failures and retryable statuses
        4. PrettyDioLogger          — non-release builds only
        5. ObserverInterceptor      — onRequest only (see below)
  → ErrorHandler.handle()  — DioException → Failure
  → Right(Response) or Left(Failure)
  → _parse<T>()     — only for the *As<T> variants
```

All methods return `Either<Failure, Response>` (fpdart), or `Either<Failure, T>` for the `*As<T>` variants. No exceptions cross the API boundary.

Internally the layers pass one private `_Call` value rather than re-listing every named parameter — a forgotten forward compiles cleanly and silently drops the argument. Only the public methods spell the parameters out.

The three-layer split in `api_service.dart` matters: the loader must be reference-counted per *caller* (outermost), de-duplication must sit above the network call, and the connectivity check must be inside the deduped call so two collapsed callers share one probe.

### Typed responses

`getAs<T>`/`postAs<T>`/`putAs<T>`/`patchAs<T>`/`deleteAs<T>` take a `parser` and route through the untyped sibling, then `_parse<T>`. A throwing parser becomes `Failure(ErrorSource.parseError, ...)` carrying the raw body in `data` — never rethrown.

`listParser(fromJson, {key})` is a top-level helper returning a `List<T> Function(dynamic)`, so list endpoints don't need five more methods on the interface.

### Error model

`ErrorHandler` converts `DioException` → `ResponseCode` (enum with inline integer raw values, negative for non-HTTP errors) → `ErrorSource` (semantic enum) → `Failure` (Equatable, with `errorType`, `code`, `message`, `data`, `statusCode`).

`Failure.data` holds the raw response body and `statusCode` the literal HTTP status — `code` collapses anything unrecognised to `defaultError`, so `statusCode` is the field to read for the real status. `Failure.validationErrors` parses a `{"errors": {field: [...]}}` body.

Message extraction lives in `src/utils/error_body.dart` (`extractErrorMessage`), shared by `ErrorHandler` and the `isSuccess` path so both surface the same message for the same body. It tries `message`, `detail`, then `error`, follows one level into a nested object, and joins a list.

`ResponseCode` internal codes: `connectTimeout(-1)`, `cancel(-2)`, `receiveTimeout(-3)`, `sendTimeout(-4)`, `noInternetConnection(-6)`, `defaultError(-7)`, `connectionFailure(-8)`, `parseError(-9)`. `-5` was `cacheError` (removed in 4.0.0) and is retired, never reused.

> Adding a variant to `ErrorSource` or `ResponseCode` is a **breaking change** — consumers switching exhaustively stop compiling. `parseError` is why 2.0.0 is a major.

### Connectivity check

`NetworkInfo` runs a pre-flight probe before every request unless `bypassConnectivityCheck` is set. The probe itself is `ApiConfig.connectivityProbe` when supplied, otherwise `internet_connection_checker_plus` — which reaches third-party hosts, so consumers behind a proxy or under a privacy review point it at their own health endpoint instead of disabling the check wholesale. The probe is a real network round-trip, so a **positive** result is cached for `connectivityCacheTtl` (default 5s) and concurrent callers share one in-flight probe.

**Negative results are deliberately never cached.** A cached `false` would keep reporting offline for seconds after the connection came back — exactly when the user is hammering retry. `probe` and `clock` are injectable so tests need neither network nor sleeps.

### Caller interceptors

`ApiConfig.interceptors` go **after auth, before retry**. After auth so a signing interceptor sees the `Authorization` header it has to cover and cannot be clobbered by the token; before retry and the logger so a replay re-runs them (a timestamped signature is regenerated per attempt rather than replayed stale) and so what the caller adds is what gets printed.

> A retry replays the *same* `RequestOptions` instance, not a copy. Reading a header off it after the fact shows the last attempt's value — tests that assert per-attempt headers must snapshot them at send time.

### Concurrency cap

`ApiConfig.maxConcurrentRequests` is enforced by `_RequestGate`, a FIFO semaphore at the bottom of `api_service.dart`, acquired inside `_performRequest` and `download`. It sits **below** de-duplication deliberately: the cap is on real network calls, so two collapsed callers consume one slot between them — which is also why a cap of 1 does not deadlock a de-duplicated pair.

The token is registered in `_activeTokens` *before* acquiring, so a request still queued is cancellable. Dio's own cancellation cannot reach the queue — it sits outside Dio — so `acquire(token)` listens to `token.whenCancel` itself and completes `false`, having taken no slot; the caller must then not `release()`. `_throughGate` wraps this for both `_performRequest` and `download`. `release()` hands the slot straight to the next waiter rather than decrementing, which keeps `_active` honest and the queue FIFO. A `null` limit short-circuits both methods, so an uncapped client tracks nothing. The limit is read once at construction, so it is a client-built setting, not a request-time one.

> **Requests made from inside `onTokenRefresh` skip the gate.** A `401`'d request holds its slot while awaiting the refresh, so a refresh sent through `ApiServices` would queue behind its own waiters — a cap of 1 deadlocked. `TokenRefreshInterceptor` runs the callback via `runAsTokenRefresh` (`src/utils/refresh_zone.dart`), a zone value that follows every async call it makes; `_throughGate` checks `isInsideTokenRefresh`. Retry backoffs still hold their slot — a throughput cost, not a deadlock.

### Token refresh (`src/interceptors/token_refresh_interceptor.dart`)

Unchanged in 2.0.0 apart from a `fromConfig` factory taking `AuthConfig`. The original multi-parameter constructor is kept because the test suite drives it directly.

> **`_shouldAttach` gates both `onRequest` and `onError`.** `baseUrl` supports absolute endpoints — the docs sell that as the way to reach a CDN or third party — so without a host check the bearer token goes wherever the caller points the client. Two consequences, not one: the token leaks, and S3 rejects a presigned URL that also carries an `Authorization` header, so the documented pattern fails. The default is "same host as `dio.options.baseUrl`", overridable per-`Uri` with `AuthConfig.sendTokenTo`; a throwing predicate fails **closed**. `onError` is gated too, or a third party's 401 would trigger a refresh and, on failure, fire `onRefreshFailed` — signing the user out of an app whose own session was never in question. An empty `baseUrl` sends everywhere, since there is nothing to compare against and blocking would break absolute-url-only clients.

On 401: checks `extra['_tokenRetried']` against loops; guards concurrent refreshes with `_isRefreshing` + `Completer<bool>` so a burst of 401s all succeed off one refresh; calls `onTokenRefresh()`, then `getToken()`, rebuilds headers, replays. `onRefreshFailed()` fires if refresh fails.

`onRequest` records a hash of the token it sent in `extra['_tokenSent']` (a hash, since `extra` is logged and handed to observers). It also records `_generation`, bumped by each successful refresh: a `401` sent under an older generation replays without refreshing — checked first, because it is synchronous — unless a refresh is running *now*, in which case the current token is the one being replaced and it waits for that refresh instead. The generation is read **before** `await getToken()`: read after, a refresh landing during the await labelled an old-token request as current, and its `401` started a redundant refresh. Failing that, a `401` whose sent token differs from the current one (changed outside the interceptor) replays without refreshing — it arrived after another request's refresh finished. That check awaits `getToken()`, so it must stay *before* the `_isRefreshing` test-and-set, which has to remain synchronous.

A `401` on a request made *from inside* `onTokenRefresh` (`isInsideTokenRefresh`) passes straight through — it is the refresh failing, and waiting would mean waiting on its own refresh until `refreshTimeout`. A `401` sent with the *new* token while the originator is still replaying under the guard replays once rather than refreshing again. That is deliberate and pinned by `holds the refresh guard until the replay finishes`: a token rejected moments after issue is likelier propagation lag than expiry, and with refresh-token rotation a second refresh can sign the user out.

`refreshTimeout` now only bounds an `onTokenRefresh` that never completes. The same zone check keeps such a request out of de-duplication.

Internally every refresh resolves to a `RefreshOutcome`. `onTokenRefresh` (bool) maps `false` *and a throw* to `sessionExpired`; `refreshSession` maps a throw to `failed`. Only `sessionExpired` fires `onRefreshFailed`; waiters timing out on `refreshTimeout` count as `failed`. Exactly one of the two callbacks is set (asserted).

`skipRefresh` exempts a request from both refresh paths but not from carrying the token; a throwing predicate exempts nothing. `isTokenExpired` triggers a **proactive** refresh in `onRequest` via `_sharedRefresh`, which joins a running refresh or starts one and clears the guard itself (no replay to hold it for). `sessionExpired` rejects the request unsent as a synthetic `401`; `failed` sends it with the old token and marks `extra['_tokenRefreshFailed']`, so its `401` does not start a second refresh immediately.

> **`_retryRequest` must be `await`ed, not merely returned.** The `finally` that clears `_isRefreshing`/`_refreshCompleter` runs as soon as the returned future is *produced*, not when it completes, so an un-awaited return releases the guard while the replay is still in flight. A 401 arriving in that window then sees no refresh in progress and starts a second one — exactly the stampede the guard exists to prevent, and worse against a backend that rotates refresh tokens. `unawaited_return_in_try_block` catches a regression here; `test/token_refresh_interceptor_test.dart` pins the behaviour.

### Retries (`src/config/retry_policy.dart`)

Two things get retried, and the idempotency rule differs between them:

- **Transport errors** (connect/receive/send timeout, connection error) — idempotent methods only (`GET`/`HEAD`/`OPTIONS`/`PUT`/`DELETE`). A `POST` may already have been processed before the timeout.
- **Status codes** in `retryableStatusCodes`. `429` and `503` are in `alwaysRetryableStatusCodes` and retry for *any* method, because the server explicitly said it did not process the request. `408`/`500`/`502`/`504` are ambiguous and stay gated on idempotency.

`retryIf` is the final veto. `Retry-After` is honoured in both delta-seconds and HTTP-date forms, clamped to `maxDelay`, and beats the computed backoff. Backoff is exponential with full jitter (`random(0, computedDelay)`), replacing 1.x's linear interval which made concurrent failures retry in lockstep. `Random` is injectable for deterministic tests.

`src/utils/http_date.dart` exists because `dart:io`'s `HttpDate` would make the package unusable on web.

### De-duplication

`_inFlight: Map<String, Future<...>>` on `ApiServicesImplementation`, keyed by method + canonical url + body. Only the originator stores and removes the entry; followers just await it.

Skipped when the caller supplies a `CancelToken` — sharing one network call would let either caller cancel the other's request — and when it passes a progress callback, since only the originator's callbacks reach Dio. Applies to `GET`, `HEAD` and `OPTIONS` — never to a write; opt out with `dedupe: false`. Also skipped inside `onTokenRefresh`: a follower never reaches the gate, so collapsing onto a queued twin would bring back the refresh deadlock.

> The key (`buildRequestKey`, `src/utils/request_key.dart`) must cover everything that changes the answer: headers (lowercased names) and `responseType` as well as url and body. Bodies are `jsonEncode`d, never `toString()`ed — a model without its own `toString` prints as `Instance of 'X'`, which made every instance the same request. An unencodable body returns a `null` key, meaning "do not collapse".

### Observer

`ApiObserver.onRequest` comes from `ObserverInterceptor`; **`onResponse` and `onFailure` are reported from `ApiServicesImplementation`, not from Dio events.** This is deliberate: `TokenRefreshInterceptor` resolves a recovered 401 with `handler.resolve(...)`, which skips the rest of the chain, so an interceptor-based observer would miss every refreshed success and would also see intermediate failures the package went on to recover from. Reporting from the service layer covers offline short-circuits, parse errors, and `isSuccess` rejections that Dio never produces an exception for.

> **Notification happens in exactly one place: `_notify`, called from `_sendRequest`** — the outermost layer, which runs once per *caller*. It must not move deeper. `_dispatch` and `_performRequest` are shared: de-duplication collapses two callers onto one `_performRequest`, so notifying from there emits one event for two calls. `download()` and `upload()`'s file-read failure bypass `_sendRequest` and call `_notify` themselves.

Inner layers therefore return failures without reporting them; they attach `Failure.requestOptions` (via `withRequest`) so `_notify` can pass the request along. `requestOptions` is excluded from `props` — `RequestOptions` has no value equality, so including it would make every real failure unequal to every other.

`ApiConfig.mapFailure` is applied in the same place — inside `_notify`, and in `_parse` for parse errors — via `mapFailure()` (`src/utils/failure_mapper.dart`), shared with `FakeApiServices._report`. Per caller, so the observer sees the mapped failure; a throwing mapper leaves the failure unchanged.

A `*As<T>` parse failure fires **both** `onResponse` (the HTTP call succeeded) and `onFailure` (the body could not be understood). Two real events; `_parse` runs per caller so it needs no special handling.

Every observer callback is wrapped in try/catch — a broken observer must never break a request. The same goes for the loader callbacks (`_callLoader`) and `AuthConfig.onRefreshFailed`: all three are typically navigation code (`navigatorKey.currentContext!`, `pop()`), which throws readily.

### Request cancellation

`_activeTokens: Map<CancelToken, List<String?>>` tracks every active token against the tags of the requests using it — a list, one entry per request, because a caller may share one token across several and the first to finish must not unregister it for the rest. `_tracked` registers it for the request's **whole** life, connectivity probe and queue included; registered later, a cancel during the probe was missed and the request went out. `reset()` calls `_close()`, which cancels everything and makes `_tracked` cancel anything that arrives later. `cancelRequest()` cancels all of them; `cancelRequest(tag: ...)` cancels only that tag's. Tokens are removed in `_tracked`'s `finally`.

A `tag` opts the request out of de-duplication for the same reason a caller-supplied `CancelToken` does: `cancelRequest(tag:)` would otherwise abort a collapsed request that a caller under a different tag — or none — is still awaiting. `_dedupeKey` returns `null` for any of these.

### Loading indicator

`ApiServices.configureLoader({onShow, onHide})`. Reference-counted via `ApiServices._activeLoadingCount` so concurrent requests share one indicator. The counter is **static**, matching the scope of the callbacks it drives — the indicator is one global widget, and a second `init()` while requests are in flight would otherwise start a fresh per-instance count against a dialog the previous client is still driving. `reset()` clears it and bumps `_loaderEpoch`; `_showLoader` returns the epoch and `_hideLoader(epoch)` ignores a stale one, or a request in flight across a `reset()` would drive the count negative and the loader would never show again. `_sendRequest` wraps its whole body in try/finally, so the loader hides on success, `Failure`, and thrown exceptions alike. `upload()` holds the loader across file reads *and* the request, passing `showLoader: false` down to `_sendRequest` to avoid double-counting.

### Uploads

`upload()` builds `FormData` from `fields`, then appends each `UploadFile` to `formData.files` — never via the map, where several files sharing a field would be duplicate keys and all but the last dropped. `UploadFile.fromPath` for mobile/desktop, `fromBytes` for web.

> `_headersFor` strips a JSON `content-type` when the body is `FormData` — from caller-supplied headers too, not just the default set. Sending it would replace the `multipart/form-data` type Dio generates, boundary included, and the server would reject the upload. An explicit `multipart/*` value is left alone.

> **Both replay paths must call `prepareForReplay` before `dio.fetch`.** `FormData.finalize()` throws `StateError` on a second read, and two paths replay a request: `NetworkRetryInterceptor` (a `429`/`503` bypasses the idempotency check, so an upload *is* retried) and `TokenRefreshInterceptor` (a `401` on an upload long enough to outlive its token). `prepareForReplay` swaps in `FormData.clone()`, which rebuilds from the same stream factory so a file part re-opens from disk. Without it both paths throw instead of retrying — silently, since `StateError` is not a `DioException`. A `Stream` body has no factory to rebuild from, so both paths check `canReplay` first and give up on one, surfacing the original `503`/`401` rather than an `unknown` wrapping the `StateError`.

### Logging

`PrettyDioLogger` is attached only when `!kReleaseMode && config.logging.enabled`. `ApiLogOptions` mirrors `PrettyDioLogger`'s constructor rather than exposing it, so the logging library can be swapped without a breaking change. `filter` is intentionally not mirrored — its callback takes `FilterArgs`, which would leak the package type.

**`logPrint` is a sink, not a switch.** Every line the logger produces passes through it, which makes it the extension point for rewriting the stream. `ApiLogOptions.trimBase64` uses it: `DioFactory._logSink` wraps the caller's sink in a `Base64LogTrimmer` (a fresh one per client — it holds a running count of elided characters), so a custom `logPrint` still receives every line, already trimmed.

> `Base64LogTrimmer` filters **lines, not fields** — the logger has already flattened the body by the time it is called, so the test is a shape test: a run of the base64 alphabet at least `minRunLength` long. Continuation lines are swallowed and counted; the first line of a blob keeps its key plus `keptChars` of value. This is why it is coupled to PrettyDioLogger's box-drawing gutter (`_gutter` strips `║╟╔╚╝═`) — **replacing the logging library breaks it silently**, with no error, just the base64 flooding back. Any logger swap must keep the same line framing or ship a matching trimmer.

### Testing notes

- `mocktail` for all mocks. Mocks created in `setUpAll` are shared across a group; `reset(mock)` in `setUp` if you need `verifyNever`.
- Two established patterns: **`MockDio` + `MockNetworkInfo`** for service-level tests, and a **fake `HttpClientAdapter`** for interceptor-level tests that drive real Dio end-to-end. Don't invent a third.
- `ApiServices.reset()` in `tearDown` for anything touching static config.
- Network-level tests mock `Dio` directly; don't mock `ApiServices` itself — use `FakeApiServices` from `lib/testing.dart`. The fake must *behave* like production, not just compile against it: it builds failures with `failureForStatus` (`error_handler.dart`) and applies `isSuccess` with `evaluateSuccess` (`success_check.dart`) — the same functions the real client uses. It also reports to `ApiConfig.observer` with production's rules: `onRequest` unless offline or pre-cancelled, then one outcome per call, both for a parse failure. Add to those rather than re-implementing logic in the fake. Anything added to the `ApiServices` interface has to land in `FakeApiServices` too, or consumers' test suites stop compiling.
