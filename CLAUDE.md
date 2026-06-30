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

Current version: **1.1.0**

### Request lifecycle

```
ApiServices.instance().get/post/put/patch/delete(endpoint, ...)
  → connectivity check via NetworkInfo (fails fast with no_internet_connection)
  → Dio.request() through interceptors:
      1. TokenRefreshInterceptor  — attaches token header on every request; retries on 401
      2. NetworkRetryInterceptor  — retries transient timeouts/connection errors (max 3, exponential backoff)
      3. PrettyDioLogger          — debug builds only
  → Response or DioException
  → ErrorHandler.handle()        — converts DioException → Failure
  → Right(Response) or Left(Failure)
```

All HTTP methods return `Either<Failure, Response>` (fpdart). Callers use `.fold(onLeft, onRight)` — there are no thrown exceptions crossing the API boundary.

### Connectivity check

`ApiServices` performs a pre-flight connectivity check before every request. This can be disabled two ways:

- Pass `bypassConnectivityCheck: true` to `ApiServices.configure(...)` (when using token auth).
- Call `ApiServices.setConnectivityCheck(enabled: false)` at any time (when not using token auth).

Useful in staging/internal environments where the connectivity probe pings external hosts that are blocked by a proxy or firewall.

### Token refresh interceptor (`src/interceptors/token_refresh_interceptor.dart`)

Stateful interceptor configured once via `ApiServices.configure(...)`. On 401:
1. Checks `request.extra['_tokenRetried']` to prevent infinite loops.
2. Guards concurrent refreshes with `_isRefreshing` + `Completer<bool>`.
3. Calls the consumer-supplied `onTokenRefresh()` callback; on success, fetches fresh token via `getToken()`, rebuilds headers, and retries the original request.
4. Calls `onRefreshFailed()` (e.g. logout) if refresh fails.

The interceptor is only added to Dio when `configure()` has been called. Without it, 401 errors surface as a `Failure` like any other HTTP error.

### Request cancellation

`ApiServicesImplementation` tracks every active `CancelToken` in a `_activeTokens: Set<CancelToken>`. `cancelRequest()` cancels all of them, not just one. Tokens are removed from the set in `_sendRequest`'s `finally` block.

### Error model

`ErrorHandler` converts `DioException` → `ResponseCode` (enum with inline integer raw values, negative for non-HTTP errors) → `ErrorSource` (semantic enum, camelCase variants) → `Failure` (Equatable value object with `errorType`, `code`, `message`).

`ResponseCode` supports: `success(200)`, `created(201)`, `noContent(204)`, `badRequest(400)`, `unauthorized(401)`, `forbidden(403)`, `notFound(404)`, `requestTimeout(408)`, `conflict(409)`, `unprocessableEntity(422)`, `tooManyRequests(429)`, `internalServerError(500)`, `badGateway(502)`, `serviceNotAvailable(503)`, plus internal codes (`connectTimeout(-1)`, `cancel(-2)`, `receiveTimeout(-3)`, `sendTimeout(-4)`, `cacheError(-5)`, `noInternetConnection(-6)`, `defaultError(-7)`, `connectionFailure(-8)`).

When the server returns a JSON body, `ErrorHandler` extracts the `message` or `error` key for the `Failure.message`. Otherwise it falls back to `ResponseStrings` string constants.

### Caching

`ApiCacheHelper` is a thin wrapper around `APICacheManager` (SQLite-backed). The cache key is `"api_cache_" + url`. Nothing in `ApiServices` touches the cache automatically — callers must call `ApiCacheHelper.instance` themselves before or after requests.

### Singleton lifecycle

`ApiServices._instance` and `ApiCacheHelper._instance` are module-level singletons. Call `ApiServices.configure(...)` once at app startup before any request. Calling `instance()` before `configure()` is valid but produces a Dio without the token interceptor. Calling `configure()` again replaces the singleton — useful for re-login after logout.

### Testing notes

- `sqflite_common_ffi` initialises an in-process SQLite for cache tests — `sqfliteFfiInit()` must be called in `setUpAll`.
- `mocktail` is used for all mocks.
- Network-level tests mock `Dio` directly; don't mock `ApiServices` itself.