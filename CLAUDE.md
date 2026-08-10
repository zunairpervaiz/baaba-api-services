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

# Format
dart format lib/ test/

# Get dependencies
flutter pub get
```

## Architecture

`baaba_api_handler` is a Flutter package (not an app) that wraps Dio into a typed, functional HTTP client. It is published and consumed by other projects — the public surface in `ts_api_handler.dart` is the contract.

### Public surface (`lib/ts_api_handler.dart`)

Re-exports only: `ApiServices`, `ApiCacheHelper`, `ErrorSource`, `Failure`, `ResponseCode`, and pass-through types `APICacheDBModel`, `CancelToken`, `Response`.

Current version: **1.4.0**

### Request lifecycle

```
ApiServices.instance().get/post/put/patch/delete/download(endpoint, ...)
  → connectivity check via NetworkInfo (fails fast with no_internet_connection)
  → Dio.request()/Dio.download() through interceptors:
      1. TokenRefreshInterceptor  — attaches token header on every request; retries on 401
      2. NetworkRetryInterceptor  — retries transient timeouts/connection errors on idempotent methods only (max 3, exponential backoff)
      3. PrettyDioLogger          — debug builds only
  → Response or DioException
  → ErrorHandler.handle()        — converts DioException → Failure
  → Right(Response) or Left(Failure)
```

All HTTP methods return `Either<Failure, Response>` (fpdart). Callers use `.fold(onLeft, onRight)` — there are no thrown exceptions crossing the API boundary.

`download({endpoint, savePath, ...})` streams the response body directly to `savePath` instead of loading it into memory, for images/PDFs/exports. It shares the connectivity check, `CancelToken` tracking, and loader plumbing with the other methods but bypasses `TokenRefreshInterceptor`/`NetworkRetryInterceptor` retry semantics that assume a buffered response — see `ApiServicesImplementation.download` in `src/api_service.dart`.

`NetworkRetryInterceptor` only retries `GET`/`HEAD`/`OPTIONS`/`PUT`/`DELETE`. `POST`/`PATCH` are never auto-retried — the server may have already processed the request before the timeout, and a blind retry could duplicate the side effect (e.g. creating the same order twice).

### Request logging

`PrettyDioLogger` is attached in `DioFactory.getDio()` only when `!kReleaseMode` **and** `logOptions.enabled`. What it prints is consumer-controlled via `ApiLogOptions` (`src/utils/api_log_options.dart`), two ways, mirroring the connectivity-check pattern:

- `logging: ApiLogOptions(...)` on `ApiServices.configure(...)` (when using token auth).
- `ApiServices.setLogging(ApiLogOptions(...))` — must run before the first `instance()` call, because the Dio client and its interceptors are built once and cached.

The options are stored in `ApiServices._logOptions` so both the `configure()` and lazy `instance()` construction paths see the same value. `ApiLogOptions` deliberately mirrors `PrettyDioLogger`'s constructor rather than exposing it — `PrettyDioLogger` is not in the public surface, so the logging library can be swapped without a breaking change. `filter` is intentionally not mirrored: its callback takes `FilterArgs`, which would leak the package type.

`ApiLogOptions()` defaults reproduce the pre-1.4.0 hardcoded behaviour (request line, request body, response body, errors), so existing callers see identical output.

### Connectivity check

`ApiServices` performs a pre-flight connectivity check before every request. This can be disabled two ways:

- Pass `bypassConnectivityCheck: true` to `ApiServices.configure(...)` (when using token auth).
- Call `ApiServices.setConnectivityCheck(enabled: false)` at any time (when not using token auth).

Useful in staging/internal environments where the connectivity probe pings external hosts that are blocked by a proxy or firewall.

### Token refresh interceptor (`src/interceptors/token_refresh_interceptor.dart`)

Stateful interceptor configured once via `ApiServices.configure(...)`. On 401:
1. Checks `request.extra['_tokenRetried']` to prevent infinite loops.
2. Guards concurrent refreshes with `_isRefreshing` + `Completer<bool>`. If a refresh is already in flight, the request awaits that same `Completer` (bounded by `refreshTimeout`, default 30s) and retries once it resolves, instead of failing immediately — so a burst of concurrent 401s (e.g. right as the token expires) all succeed off one refresh rather than only the first.
3. Calls the consumer-supplied `onTokenRefresh()` callback; on success, fetches fresh token via `getToken()`, rebuilds headers, and retries the original request.
4. Calls `onRefreshFailed()` (e.g. logout) if refresh fails.

`refreshTimeout` exists to avoid a deadlock in the pathological case where the refresh endpoint itself 401s (refresh token expired) — that inner call is queued behind the very refresh it's part of, so it needs a bound to give up and surface the original error.

The interceptor is only added to Dio when `configure()` has been called. Without it, 401 errors surface as a `Failure` like any other HTTP error.

### Request cancellation

`ApiServicesImplementation` tracks every active `CancelToken` in a `_activeTokens: Set<CancelToken>`. `cancelRequest()` cancels all of them, not just one. Tokens are removed from the set in `_sendRequest`'s `finally` block.

### Loading indicator

`ApiServices.configureLoader({onShow, onHide})` registers a global, framework-agnostic loading indicator. `_sendRequest` wraps its entire body (connectivity check, request, error handling) in a `try/finally` that calls `_showLoader()`/`_hideLoader()` on `ApiServicesImplementation`, so `onShow`/`onHide` fire around success, `Failure`, and thrown exceptions alike. Calls are reference-counted via `_activeLoadingCount` so concurrent requests share one indicator (`onShow` only on the 0→1 transition, `onHide` only on 1→0). Each HTTP method takes a `showLoader` parameter (default `true`) to opt a specific request out. The package has no UI dependency — `onShow`/`onHide` are plain closures the consumer wires to their own dialog (e.g. `Get.dialog`/`Get.back` for GetX).

### Error model

`ErrorHandler` converts `DioException` → `ResponseCode` (enum with inline integer raw values, negative for non-HTTP errors) → `ErrorSource` (semantic enum, camelCase variants) → `Failure` (Equatable value object with `errorType`, `code`, `message`).

`ResponseCode` supports: `success(200)`, `created(201)`, `noContent(204)`, `badRequest(400)`, `unauthorized(401)`, `forbidden(403)`, `notFound(404)`, `requestTimeout(408)`, `conflict(409)`, `unprocessableEntity(422)`, `tooManyRequests(429)`, `internalServerError(500)`, `badGateway(502)`, `serviceNotAvailable(503)`, plus internal codes (`connectTimeout(-1)`, `cancel(-2)`, `receiveTimeout(-3)`, `sendTimeout(-4)`, `cacheError(-5)`, `noInternetConnection(-6)`, `defaultError(-7)`, `connectionFailure(-8)`).

When the server returns a JSON body, `ErrorHandler` extracts the `message`, `detail`, or `error` key for the `Failure.message`. Otherwise it falls back to `ResponseStrings` string constants.

### Caching

`ApiCacheHelper` is a thin wrapper around `APICacheManager` (SQLite-backed). The cache key is `"api_cache_" + url`. Nothing in `ApiServices` touches the cache automatically — callers must call `ApiCacheHelper.instance` themselves before or after requests.

`getCacheData(url, {maxAge})` takes an optional freshness window: if the cached entry is older than `maxAge`, it's deleted and `null` is returned instead of stale data. Omit `maxAge` to get cached data regardless of age (unchanged default behavior).

### Singleton lifecycle

`ApiServices._instance` and `ApiCacheHelper._instance` are module-level singletons. Call `ApiServices.configure(...)` once at app startup before any request. Calling `instance()` before `configure()` is valid but produces a Dio without the token interceptor. Calling `configure()` again replaces the singleton — useful for re-login after logout.

### Testing notes

- `sqflite_common_ffi` initialises an in-process SQLite for cache tests — `sqfliteFfiInit()` must be called in `setUpAll`.
- `mocktail` is used for all mocks.
- Network-level tests mock `Dio` directly; don't mock `ApiServices` itself.