# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Layout

```
packages/baaba_api_handler/     the published client (+ example/)
packages/baaba_api_generator/   the published build_runner generator
```

Sibling packages, **not** a pub workspace and **not** nested (see "Code generation" for why). Unless a path says otherwise, paths in this file are relative to `packages/baaba_api_handler/`.

## Commands

Run from `packages/baaba_api_handler/`:

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

# The generator package (separate resolution — see "Code generation")
cd ../baaba_api_generator && flutter pub get && dart test && dart analyze

# The example: regenerate its parts after touching the generator or example/env/
cd example && dart run build_runner build && flutter test
```

Three packages, each with its own `pubspec.yaml` and lockfile: the handler, the generator, and the handler's `example/`. Run commands from the package's own directory.

## Architecture

`baaba_api_handler` is a Flutter package (not an app) that wraps Dio into a typed, functional HTTP client. It is published and consumed by other projects — the public surface in `ts_api_handler.dart` is the contract.

### Public surface

Two identical entrypoints: `lib/baaba_api_handler.dart` (conventional) and `lib/ts_api_handler.dart` (predates the rename, still the canonical file). A third, `lib/testing.dart`, ships `FakeApiServices` for consumers' tests and is never imported by production code. `lib/annotations.dart` exports `@BaabaApiEndpoint`/`@BaabaApiEnvironment`/`@BaabaApiField`, `ApiEndpoint` and the `@internal` `decodeObfuscated`; it must stay **Flutter-free**, because `baaba_api_generator` imports it and builders run on the plain Dart VM. The main library re-exports it. A fourth, `lib/io.dart`, ships `pinnedHttpClient`/`pinnedIoClient` and imports `dart:io` — it is the **only** public library allowed to; the core must stay web-safe (see Transport).

Exports: `ApiServices`, `ApiConfig`, `AuthConfig`, `RetryPolicy`, `PinningConfig`/`UnlistedHostPolicy`, `ProxyConfig`, `ApiEndpoint`, `ApiObserver`, `ApiLogOptions`, `Base64LogTrimmer`, `UploadFile`, `Failure`, `ErrorSource`, `ResponseCode`, `HttpMethod`/`HttpMethodExtension`, `listParser`, `ApiException`/`ApiResultOrThrow`/`EitherOrThrow`/`guardApi`, `jwtExpired`/`jwtExpiryCheck`, plus pass-throughs `Either`/`Left`/`Right` (fpdart), `Response`/`CancelToken`/`FormData`/`MultipartFile`/`RequestOptions`/`ResponseType` (Dio).

Current version: **5.0.1** (unreleased). Latest on pub.dev is **5.0.0** (commit `ef4b720`; 3.0.0 and 3.1.0 were never published). Published CHANGELOG/MIGRATION sections describe what shipped and must not change; until 5.0.1 is published, new changes go into the 5.0.1 section. 5.0.0 is major only because of `certificateRejected`. `baaba_api_generator` 1.0.0 is published (1.0.1 unreleased) and requires `baaba_api_handler: ^5.0.0`, so a release needing new handler API publishes the handler first. SDK floor: Dart 3.8 / Flutter 3.32 — the oldest the dev tooling (`flutter_lints` 6) can actually build, so the constraint never claims more than is tested.

Response caching (`CachePolicy`, `ApiCacheHelper`, the `api_cache_manager`/SQLite dependency) was removed in 4.0.0. Don't reintroduce a persistence dependency without discussing it — the package deliberately persists nothing.

### Configuration

Everything lives on one `ApiConfig` object passed to `ApiServices.init(...)`. This replaced four separate static mutables in 2.0.0 — with nine features to configure, a setter per feature meant a dozen statics with load-order footguns.

**Named clients.** `ApiServices` keeps per-name registries as statics: `_instances` and `_configs` (keyed by name, `ApiServices.defaultClient` = `'default'` for the unnamed one), `_sharedLoader`, and `_ownLoaders`. `init(config, {name})` builds one; `instance()` is the default (built lazily, as always); `named(name)` throws `StateError` for a name never `init`ed — a named client is deliberately never built on demand. Each `ApiServicesImplementation` carries its `_name` and reads **its own** config through the `_config` getter (`ApiServices.configOf(_name)`). Never read another client's config, and never add a bare static read of configuration — every request-time setting must go through `_config`. The gate is built from the named config at construction. The 1.x setters (`configure()`, `setConnectivityCheck()`, `setLogging()`) were deprecated in 2.0.0 and removed in 3.0.0; `init()` is the only way to configure.

**Which settings apply when.** Anything read at request time — `bypassConnectivityCheck`, `isSuccess`, `onRejected`, `mapFailure`, `observer` — takes effect immediately because the implementation reads `_configs[name]` per call (so even a caller holding a stale instance from before the last `init` of that name sees it). Anything baked into the Dio client or the `NetworkInfo` — `baseUrl`, timeouts, `logging`, `retry`, `auth`, `httpClientAdapter`, `pinning`, `proxy`, `connectivityProbe`, `connectivityCacheTtl`, `maxConcurrentRequests` — applies only to the client built by that `init()` call.

**URL joining.** `DioFactory` stores `normalizeBaseUrl(baseUrl)` (trailing slashes trimmed) and the service layer passes `resolveEndpointPath(config.baseUrl, endpoint)` to Dio (`src/utils/url_join.dart`), which only prefixes a missing leading slash. Dio concatenates and only collapses `//` when the url has a single `:/`, so without this `https://x/v1` + `users` became `/v1users`. Never strip a caller's leading slash: `skipRefresh` and observers match on `options.path` as written. `ApiEndpoint` (`src/endpoint/`) is an extension type over `String` — keep it zero-cost and never make a method require it.

A throwing `isSuccess` counts as a rejection (fails closed, via `_accepts`). It is not applied to `head()` or `download()` — neither has a body to judge, so a body-reading predicate would reject every call; `FakeApiServices` skips them too (`evaluate: false`). `isSuccess` rejections route through `onRejected` first, which may return a `Failure` of its own; `null` or a throwing builder falls back to the generic `badRequest`.

`ApiServices.reset({name})` clears that client (or, with no name, every client), its config, and its loader, and cancels the old client's in-flight requests — otherwise one finishing after a logout still carries the previous user's token and reports to their observer. It also closes the old Dio when the package built its adapter (`_ownsTransport`: no caller-supplied `httpClientAdapter` or test `Dio`) — a caller's adapter may be shared and is theirs to close. `init()` deliberately does not cancel. Tests should call it in `tearDown`.

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

`ResponseCode` internal codes: `connectTimeout(-1)`, `cancel(-2)`, `receiveTimeout(-3)`, `sendTimeout(-4)`, `noInternetConnection(-6)`, `defaultError(-7)`, `connectionFailure(-8)`, `parseError(-9)`, `certificateRejected(-10)`. `-5` was `cacheError` (removed in 4.0.0) and is retired, never reused.

> Adding a variant to `ErrorSource` or `ResponseCode` is a **breaking change** — consumers switching exhaustively stop compiling. `parseError` is why 2.0.0 is a major; `gatewayTimeout` shipped in 4.0.0; `certificateRejected` is why 5.0.0 is a major.

### Connectivity check

`NetworkInfo` runs a pre-flight probe before every request unless `bypassConnectivityCheck` is set. The probe itself is `ApiConfig.connectivityProbe` when supplied, otherwise `internet_connection_checker_plus` — which reaches third-party hosts, so consumers behind a proxy or under a privacy review point it at their own health endpoint instead of disabling the check wholesale. The probe is a real network round-trip, so a **positive** result is cached for `connectivityCacheTtl` (default 5s) and concurrent callers share one in-flight probe.

**Negative results are deliberately never cached.** A cached `false` would keep reporting offline for seconds after the connection came back — exactly when the user is hammering retry. `probe` and `clock` are injectable so tests need neither network nor sleeps.

### Caller interceptors

`ApiConfig.interceptors` go **after auth, before retry**. After auth so a signing interceptor sees the `Authorization` header it has to cover and cannot be clobbered by the token; before retry and the logger so a replay re-runs them (a timestamped signature is regenerated per attempt rather than replayed stale) and so what the caller adds is what gets printed.

> A retry replays the *same* `RequestOptions` instance, not a copy. Reading a header off it after the fact shows the last attempt's value — tests that assert per-attempt headers must snapshot them at send time.

### Concurrency cap

`ApiConfig.maxConcurrentRequests` is enforced by `_RequestGate`, a FIFO semaphore at the bottom of `api_service.dart`, acquired inside `_performRequest` and `download`. It sits **below** de-duplication deliberately: the cap is on real network calls, so two collapsed callers consume one slot between them — which is also why a cap of 1 does not deadlock a de-duplicated pair.

The token is registered in `_activeTokens` *before* acquiring, so a request still queued is cancellable. Dio's own cancellation cannot reach the queue — it sits outside Dio — so `acquire(token)` listens to `token.whenCancel` itself — **once per token** (an `Expando` flag), since a future cannot be unsubscribed and a listener per waiter kept every waiter alive — and on cancel completes every waiter queued under it with `false`, having taken no slot; the caller must then not `release()`. `_throughGate` wraps this for both `_performRequest` and `download`. `release()` hands the slot straight to the next waiter rather than decrementing, which keeps `_active` honest and the queue FIFO. A `null` limit short-circuits both methods, so an uncapped client tracks nothing. The limit is read once at construction, so it is a client-built setting, not a request-time one.

> **Requests made from inside `onTokenRefresh` skip the gate.** A `401`'d request holds its slot while awaiting the refresh, so a refresh sent through `ApiServices` would queue behind its own waiters — a cap of 1 deadlocked. `TokenRefreshInterceptor` runs the callback via `runAsTokenRefresh` (`src/utils/refresh_zone.dart`), a zone value that follows every async call it makes; `_throughGate` checks `isInsideTokenRefresh`. Retry backoffs still hold their slot — a throughput cost, not a deadlock.

### Token refresh (`src/interceptors/token_refresh_interceptor.dart`)

Unchanged in 2.0.0 apart from a `fromConfig` factory taking `AuthConfig`. The original multi-parameter constructor is kept because the test suite drives it directly.

> **`_shouldAttach` gates both `onRequest` and `onError`.** `baseUrl` supports absolute endpoints — the docs sell that as the way to reach a CDN or third party — so without a host check the bearer token goes wherever the caller points the client. Two consequences, not one: the token leaks, and S3 rejects a presigned URL that also carries an `Authorization` header, so the documented pattern fails. The default is "same host as `dio.options.baseUrl`", overridable per-`Uri` with `AuthConfig.sendTokenTo`; a throwing predicate fails **closed**. `onError` is gated too — on the original host *and* (`_answeredByUs`) on the final host, resolving each redirect against the hop before it (dart:io records `Location` unresolved), since a redirect is followed inside one Dio call — or a third party's 401 would trigger a refresh and, on failure, fire `onRefreshFailed` — signing the user out of an app whose own session was never in question. An empty `baseUrl` sends everywhere, since there is nothing to compare against and blocking would break absolute-url-only clients.

On 401: checks `extra['_tokenRetried']` against loops; guards concurrent refreshes with `_isRefreshing` + `Completer<bool>` so a burst of 401s all succeed off one refresh; calls `onTokenRefresh()`, then `getToken()`, rebuilds headers, replays. `onRefreshFailed()` fires if refresh fails.

`onRequest` records a hash of the token it sent in `extra['_tokenSent']` (a hash, since `extra` is logged and handed to observers). It also records `_generation`, bumped by each successful refresh: a `401` sent under an older generation replays without refreshing — checked first, because it is synchronous — unless a refresh is running *now*, in which case the current token is the one being replaced and it waits for that refresh instead. The generation is read **before** `await getToken()`: read after, a refresh landing during the await labelled an old-token request as current, and its `401` started a redundant refresh. Failing that, a `401` whose sent token differs from the current one (changed outside the interceptor) replays without refreshing — it arrived after another request's refresh finished. That check awaits `getToken()`, so it must stay *before* the `_isRefreshing` test-and-set, which has to remain synchronous — and it re-checks the generation after the await, since a whole refresh can run inside one `getToken()` call.

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

Skipped when the caller supplies a `CancelToken` — sharing one network call would let either caller cancel the other's request — when it passes a progress callback, since only the originator's callbacks reach Dio, and when it passes its own `receiveTimeout`/`sendTimeout`, or a follower would inherit the originator's deadline. Applies to `GET`, `HEAD` and `OPTIONS` — never to a write; opt out with `dedupe: false`. Also skipped inside `onTokenRefresh`: a follower never reaches the gate, so collapsing onto a queued twin would bring back the refresh deadlock.

> The key (`buildRequestKey`, `src/utils/request_key.dart`) must cover everything that changes the answer: headers (lowercased names) and `responseType` as well as url and body. The url part is built with `normalizeBaseUrl`/`resolveEndpointPath`, the same functions that build Dio's url, so `''` and `'/'` never share a key; header pairs are `jsonEncode`d so a value containing `,` cannot fake a boundary. Bodies are `jsonEncode`d, never `toString()`ed — a model without its own `toString` prints as `Instance of 'X'`, which made every instance the same request. An unencodable body returns a `null` key, meaning "do not collapse".

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

`ApiServices.configureLoader({onShow, onHide, name})`. Accounting lives on a private `_Loader` (callbacks, `_count`, `_epoch`), **not** on the client: the indicator is a widget, and a second `init()` while requests are in flight would otherwise start a fresh per-instance count against a dialog the previous client is still driving. Without a name it configures `_sharedLoader`, used by every client that has no loader of its own — so a request on each of two clients opens the dialog once. `configureLoader(name:)` gives that client its own `_Loader`. `_showLoader` returns a hold `(loader, epoch)` and `_hideLoader` releases on *that* loader, so a loader reassigned mid-request is still released correctly. `_Loader.discard()` (called by `reset`) hides a showing indicator, zeroes the count and bumps the epoch; a stale hold is ignored, or a request in flight across a `reset()` would drive the count negative and the loader would never show again. `reset(name: x)` discards only `x`'s own loader; the shared one goes with `reset()` or `reset(name: defaultClient)`. `_sendRequest` wraps its whole body in try/finally, so the loader hides on success, `Failure`, and thrown exceptions alike. `upload()` holds the loader across file reads *and* the request, passing `showLoader: false` down to `_sendRequest` to avoid double-counting.

### Uploads

`upload()` builds `FormData` from `fields`, then appends each `UploadFile` to `formData.files` — never via the map, where several files sharing a field would be duplicate keys and all but the last dropped. `UploadFile.fromPath` for mobile/desktop, `fromBytes` for web.

> `_headersFor` strips a JSON `content-type` when the body is `FormData` — from caller-supplied headers too, not just the default set. Sending it would replace the `multipart/form-data` type Dio generates, boundary included, and the server would reject the upload. An explicit `multipart/*` value is left alone.

> **Both replay paths must call `prepareForReplay` before `dio.fetch`.** `FormData.finalize()` throws `StateError` on a second read, and two paths replay a request: `NetworkRetryInterceptor` (a `429`/`503` bypasses the idempotency check, so an upload *is* retried) and `TokenRefreshInterceptor` (a `401` on an upload long enough to outlive its token). `prepareForReplay` swaps in `FormData.clone()`, which rebuilds from the same stream factory so a file part re-opens from disk. Without it both paths throw instead of retrying — silently, since `StateError` is not a `DioException`. A `Stream` body has no factory to rebuild from, so both paths check `canReplay` first and give up on one, surfacing the original `503`/`401` rather than an `unknown` wrapping the `StateError`.

### Logging

`PrettyDioLogger` is attached only when `!kReleaseMode && config.logging.enabled`. `ApiLogOptions` mirrors `PrettyDioLogger`'s constructor rather than exposing it, so the logging library can be swapped without a breaking change. `filter` is intentionally not mirrored — its callback takes `FilterArgs`, which would leak the package type.

**`logPrint` is a sink, not a switch.** Every line the logger produces passes through it, which makes it the extension point for rewriting the stream. `ApiLogOptions.trimBase64` uses it: `DioFactory._logSink` wraps the caller's sink in a `Base64LogTrimmer` (a fresh one per client — it holds a running count of elided characters), so a custom `logPrint` still receives every line, already trimmed.

**Binary bodies are summarized before the logger sees them.** `RedactingLogInterceptor` always wraps the logger — even with `redact: false`, when its `redactor` is `null` — and first runs `BinaryLogSummary` (`src/utils/binary_log_summary.dart`), which replaces a binary body with `<N bytes, type>` on a copy. Otherwise a `ResponseType.bytes` image printed one number per line. In a request only `TypedData` counts as binary (a plain `List<int>` may be a JSON array); in a response, `TypedData` or a `List<int>` asked for with `ResponseType.bytes`. Copies share `extra`, like the redactor's.

> `Base64LogTrimmer` filters **lines, not fields** — the logger has already flattened the body by the time it is called, so the test is a shape test: a run of the base64 alphabet at least `minRunLength` long. Continuation lines are swallowed and counted; the first line of a blob keeps its key plus `keptChars` of value. This is why it is coupled to PrettyDioLogger's box-drawing gutter (`_gutter` strips `║╟╔╚╝═`) — **replacing the logging library breaks it silently**, with no error, just the base64 flooding back. Any logger swap must keep the same line framing or ship a matching trimmer.

### Redaction

`ApiLogOptions.redact` (default on) masks `Authorization` (always) plus `redactHeaders`, `redactQueryParams` (in `queryParameters` **and** a query written into the path) and `redactBodyFields` (JSON maps/lists at any depth, JSON strings, form-urlencoded strings, `FormData` fields; request and response bodies) and query secrets in `Response.redirects`. Only headers, query params and body fields named `*token*` keep a `redactKeepChars` prefix; other body fields are masked entirely. Implemented by `Redactor` (`src/utils/redactor.dart`), cached per `ApiLogOptions` instance via `Expando`, copy-on-write so an untouched body is returned as the same instance.

It applies in **two** places and both must stay covered: the logger, via `RedactingLogInterceptor`, which hands PrettyDioLogger masked copies and throwaway handlers (whose futures are `ignore()`d — `ErrorInterceptorHandler.next` completes with an error nobody listens to), and the observer (`ObserverInterceptor`, `_notifyResponse`/`_notifyFailure`, and `FakeApiServices._observe*`). The masked `RequestOptions` copy **shares `extra`** with the original: PrettyDioLogger stamps its start time there on request and reads it off the response. Never redact the real request, response or the `Failure` the caller gets. Unlike `Base64LogTrimmer`, this does not depend on the logger's line format.

### Transport: pinning and proxy

`ApiConfig.pinning`/`proxy` are turned into an adapter by `createTransportAdapter` in `src/transport/transport.dart`, a **conditional export** (`transport_stub.dart` on web → `null`, `transport_io.dart` when `dart.library.io`). Nothing else in the core may import `dart:io` or `package:dio/io.dart`; `isTlsError` lives there too so `ErrorHandler` can recognise a `TlsException` without importing `dart:io`.

`PinnedRoutingAdapter` follows redirects itself (each hop with `followRedirects: false`, the methods and statuses `HttpClient` follows, its credential headers — `Authorization`, `Cookie`, ... — dropped across origins), so every hop goes through `rootsFor` and the unlisted-host policy — left to `HttpClient`, a redirect would be followed inside the first hop's `SecurityContext`. Plain `http` to a pinned host is refused. It keeps one `IOHttpClientAdapter` per distinct root set (built lazily, so a bad PEM throws inside `fetch` and fails closed) plus one on the system store. It also follows redirects itself for a request carrying the token in a header `HttpClient` keeps on a cross-origin hop: `TokenRefreshInterceptor._attach` records every `headerBuilder` header name in `extra['_tokenHeaders']` (`src/utils/token_headers.dart`), and a cross-origin hop drops those plus `HttpClient`'s own list. That is why `createTransportAdapter` returns the adapter whenever `AuthConfig.headerBuilder` is set, pinning or not. Web and a caller's `httpClientAdapter` are out of reach — documented, not fixable. `buildHttpClient` sets `idleTimeout` to Dio's 3s, since a supplied client keeps `HttpClient`'s 15s. **No `badCertificateCallback`, ever** — pinning relies on `SecurityContext(withTrustedRoots: false)` failing the handshake. A `TlsException` (or a `DioException` wrapping one) is rethrown as `DioExceptionType.badCertificate` → `ErrorSource.certificateRejected` (`-10`). The proxy is `HttpClient.findProxy` on every client the adapter builds, so `https` is tunnelled with `CONNECT` and still verified against the pinned context. `httpClientAdapter` and `pinning`/`proxy` are mutually exclusive: an assert in `ApiConfig` (a `const` constructor, so it cannot call `isActive`) plus an `ArgumentError` in `DioFactory` for `pinning` or an active `proxy`, since in release the adapter would otherwise win and pinning vanish silently. The redirect loop follows exactly `HttpClient`'s set: any redirect for `GET`/`HEAD`, only a `303` for `POST` (re-sent as a body-less `GET`).

### Per-call retry and extras

Every request method takes `bool? retryable` and `Map<String, dynamic>? extra`, carried on `_Call` and merged by `_extraFor` into a **copy** for `Options.extra`, the flag under `RetryPolicy.retryableKey`. `NetworkRetryInterceptor._isRetryableFailure` checks it first: `false` vetoes everything (even `429`/`503`); `true` stands in for idempotency, leaving the status list, `maxRetries` and `retryIf` in charge. Both are part of the de-duplication key.

### Code generation (`packages/baaba_api_generator/`)

**Not a pub workspace, deliberately.** A workspace forces one resolution across all members, and Flutter's pinned `test_api`/`vm_service` (via `flutter_test`) conflict with the `build_test` versions that support analyzer 14. So the generator resolves on its own: its pubspec asks for `baaba_api_handler: ^5.0.0`, and the committed `pubspec_overrides.yaml` points that at `../baaba_api_handler` for development (publish shows a hint about it; expected). The example, which uses both, needs `dependency_overrides` for the handler for the same reason. The generator's SDK floor is 3.11 (source_gen 4) — it only constrains the build, not the handler.

**Not nested either.** Pub reads `.pubignore` by path from the git root, identically for every package, so with the generator inside the handler's directory no rule could both keep it out of the handler's archive and let it publish itself. Hence the sibling `packages/` layout.

`SharedPartBuilder` with two `GeneratorForAnnotation`s (`EndpointsGenerator`, `EnvironmentGenerator`, `lib/src/generators.dart`), combined into `*.g.dart` by source_gen. Both work on a **typedef** (`typedef Endpoints = _Endpoints;` — every key; static access through a class alias is legal Dart) or a **class** with static fields (the envied shape — only declared non-`const` fields; a missing key is an error; an untyped field is an error, since its type would be inferred from the part being generated). `abstract final class X = _X;` is not valid Dart for statics, which is why the typedef form exists.

Invariants:

- **The plain value is never written when obfuscating** — not in code, not in a comment, not via a literal like `'true'`, and not via its length: a bool is stored as `'1'`/`'0'` and compared by code unit, an int signed and zero-padded to 20 characters. `generator_test.dart` scans the output for values, fragments and any quote character.
- Keys come from `Random.secure`, one per code unit, with the low 16 bits never `0` (a zero there would leave that unit in clear — the high bits are random but don't touch it), and below 2^31 so web's 32-bit bitwise ops are safe. Values decode lazily through a `static final`.
- Storage is named `_v0`, `_v1`, ...; a class-form field matching that shape (`Emitter.isStorageName`) is a build error, or the generated class would declare it twice.
- A class-form field's default key (`keyForMemberName`) must round-trip with the typedef form's `memberNameForKey`: a digit stays with its word (`s3Bucket` ↔ `S3_BUCKET`). `keysForMemberName` also tries 1.0.0's split-digit spelling (`S_3_BUCKET`) so existing files keep building.
- Generated member names exclude reserved words and `Object`'s members (`hashCode`, `toString`, ...); placeholder names exclude `ApiEndpoint`/`Object`, which the method body refers to.
- Named placeholders are rewritten to `{}` before storing, so `ApiEndpoint.fill` (positional only) fills them; the parameter list keeps the names.
- Build errors are `InvalidGenerationSourceError`s carrying `path:line` and the key. The missing-file message must keep spelling out the `build.yaml` `sources` fix — that omission is the most common setup failure.
- The generated header ignores `invalid_use_of_internal_member` (for `decodeObfuscated`) and `unused_element`/`unused_field` — the analyzer does not count uses that reach the private class through the public typedef, so every typedef member would otherwise warn.

`decodeObfuscated` is `@internal`; each public library that re-exports it carries `// ignore: invalid_export_of_internal_element`. Generated code refers to handler names unqualified, so the annotated library must import the handler without a prefix.

Generator tests use build_test (`test/support.dart` copies the handler's and `meta`'s sources from one `loadIsolateSources()`; with `build_to: cache` the part lands under `.dart_tool/build/generated/`). Goldens mask the random lists. The end-to-end proof is the example: `example/test/endpoints_test.dart` runs the real generated code. Its `*.g.dart` are committed (un-ignored in `.gitignore` and `.pubignore`), so they churn on every rebuild.

### Testing notes

- `mocktail` for all mocks. Mocks created in `setUpAll` are shared across a group; `reset(mock)` in `setUp` if you need `verifyNever`.
- Two established patterns: **`MockDio` + `MockNetworkInfo`** for service-level tests, and a **fake `HttpClientAdapter`** for interceptor-level tests that drive real Dio end-to-end. Don't invent a third — with one scoped exception: pinning and proxying can only be proven by a real handshake, so `pinning_test.dart` and `proxy_test.dart` run a local HTTPS server and a `CONNECT` proxy (`test/support/`) against the throwaway CA in `test/fixtures/tls/`. `redirect_token_test.dart` likewise runs two local HTTP servers, since only a real redirect proves a header is dropped. Keep real sockets confined to transport tests.
- `ApiServices.reset()` in `tearDown` for anything touching static config.
- Network-level tests mock `Dio` directly; don't mock `ApiServices` itself — use `FakeApiServices` from `lib/testing.dart`. The fake must *behave* like production, not just compile against it: it builds failures with `failureForStatus` (`error_handler.dart`) and applies `isSuccess` with `evaluateSuccess` (`success_check.dart`) — the same functions the real client uses. It also reports to `ApiConfig.observer` with production's rules: `onRequest` unless offline or pre-cancelled, then one outcome per call, both for a parse failure. Add to those rather than re-implementing logic in the fake. Anything added to the `ApiServices` interface has to land in `FakeApiServices` too, or consumers' test suites stop compiling.
