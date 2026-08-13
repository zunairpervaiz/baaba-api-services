## 2.0.0

Everything from 1.x keeps working — the old entrypoints are deprecated, not removed. See `MIGRATION.md` for the three things that can actually break you.

### ⚠️ Behaviour changes to know about before upgrading

* **Requests now time out.** 1.x set no timeout at any layer, so a request to an unreachable-but-not-refusing host hung until the OS gave up. The defaults are 30s each for connect/receive/send. If you have an endpoint that legitimately takes longer — a slow export or report — raise `receiveTimeout` for that call or globally, rather than removing the bound.
* **`ErrorSource` and `ResponseCode` gained a `parseError` variant.** If you `switch` exhaustively over either enum, that switch no longer compiles until you add a case. This is the only source-breaking change and the reason this is a major release.
* **`Failure` equality now includes `data` and `statusCode`.** Two failures that differ only in response body are no longer equal.

### Fixed

* **`ApiCacheHelper.getCacheData` threw on a cache miss.** The underlying `APICacheManager.getCacheData` calls `.first` on an empty query result, so asking for a URL that was never cached raised `StateError` despite the nullable return type promising otherwise. It now returns `null`.
* **Concurrent writes to one cache key could poison it permanently.** `APICacheManager.addCacheData` checks `isAPICacheKeyExist` and then inserts or updates, with no transaction around the pair, so two overlapping writes both insert. The duplicate rows are not self-correcting: `isAPICacheKeyExist` answers `rows.length == 1`, so it then reports the key as missing forever while every further write appends another row. Request de-duplication makes overlapping same-key writes routine rather than rare, so `setCacheData` now serialises writes per key.
* **Uploads threw instead of retrying.** A `FormData` is a stream Dio reads once — `finalize()` throws `StateError` on a second read. Both replay paths hit it: a `429`/`503` retry (those bypass the idempotency check, so an upload *is* retried) and a `401` token refresh, which is a likely outcome for an upload long enough to outlive its token. The body is now rebuilt with `FormData.clone()` before either replay.
* **A JSON `content-type` in caller-supplied headers broke multipart uploads.** It was only stripped from the package's default headers, so an upload that also needed, say, an `X-Tenant-Id` header silently sent `application/json` and lost the multipart boundary.
* **A connectivity probe that threw synchronously disabled the check permanently.** An `async` body runs synchronously to its first `await`, so such a probe completed — and cleared the in-flight slot — before that slot was assigned, stranding a completed future that reported offline for the rest of the session.
* **Cached entries with query parameters collided.** The cache key was the raw url, so `/users` with `params: {'page': 1}` and `page: 2` shared one entry and the second overwrote the first. Query parameters are now part of the key, sorted so argument order does not matter.
* **The connectivity probe ran before every single request** — a real network round-trip that roughly doubled the latency of a fast API call. A positive result is now reused for `connectivityCacheTtl` (default 5s). Negative results are deliberately never cached, since that is exactly when the user is retrying.
* **`Failure` discarded the response body**, making `422` field errors unreachable.
* Interceptor order was assembled across two call sites and did not match the documented order. It is now fixed in one place, with auth before retry so a retried request carries a valid token.
* `DioExceptionType.badCertificate` mapped to the generic "unexpected error" instead of `connectionFailure`.

### Added

* **`ApiConfig` + `ApiServices.init(...)`** — one object for every setting, replacing `configure()` and the loose static setters. Adds `baseUrl` (so call sites pass `/users`, not the full URL), `connectTimeout`/`receiveTimeout`/`sendTimeout`, and `defaultHeaders`.
* **Typed responses** — `getAs<T>`, `postAs<T>`, `putAs<T>`, `patchAs<T>`, `deleteAs<T>` take a `parser` and return `Either<Failure, T>`. A throwing parser becomes a `Failure` with `ErrorSource.parseError` carrying the raw body; no exception escapes. `listParser(User.fromJson)` handles list endpoints, with an optional `key` for `{"data": [...]}` wrappers.
* **Response caching** — `cachePolicy` and `cacheMaxAge` on `get`/`getAs`, with `CachePolicy.cacheFirst`, `networkFirst`, `cacheOnly`, and the default `networkOnly` (unchanged behaviour). `response.isFromCache` tells you which you got. `ApiCacheHelper` was already in the package but nothing called it.
* **Project-level cache control** — `ApiConfig.cacheEnabled: false` forbids caching outright, overriding any `cachePolicy` a call site passes and never opening the database; `ApiConfig.defaultCachePolicy` sets the policy for calls that don't name one. Not every app should cache, and "just don't pass a policy" relies on every call site getting it right.
* **`ApiLogOptions.trimBase64`** — collapses base64 blobs in log output. An API returning photographs or fingerprints inline turns a single response into thousands of console lines, because the logger wraps every value at `maxWidth` and has no notion of a field worth hiding. With this on, a blob prints as a recognisable head plus a count of what was elided, and everything else passes through byte for byte. Off by default. `Base64LogTrimmer` is exported for tuning `minRunLength`/`keptChars` or placing the trimmer in front of your own sink.
* **In-flight de-duplication** — two identical GETs at the same time share one network call. Skipped automatically when you pass your own `CancelToken`, since cancelling one caller must not cancel the other; opt out with `dedupe: false`.
* **`RetryPolicy`** — configurable `maxRetries`, `baseDelay`, `maxDelay`, `retryableStatusCodes`, and a `retryIf` predicate. Retries now cover status codes as well as transport errors: `429` and `503` for any method (the server told us it did not process the request), `408`/`500`/`502`/`504` for idempotent methods only. `Retry-After` is honoured in both its delta-seconds and HTTP-date forms. Backoff is exponential with full jitter, replacing the lockstep linear interval that made concurrent failures retry in unison.
* **`ApiConfig.isSuccess`** — treat a `200` carrying `{"success": false}` as a failure, with the message pulled from the body the same way a real error response would be.
* **`ApiObserver`** — one hook for every request, response, and failure, for Sentry/Crashlytics/analytics. Fires exactly once per call, including for failures Dio never produces an exception for (offline short-circuits, parse errors, `isSuccess` rejections). A throwing observer can never break a request.
* **`ApiConfig.httpClientAdapter`** — supply your own adapter for certificate pinning or to route through Charles/Proxyman. Deliberately consumer-supplied so the package stays usable on web.
* **`upload()`** — multipart uploads with progress, taking `UploadFile.fromPath` (mobile/desktop) or `UploadFile.fromBytes` (web, where a picked file has no path). The multipart body is rebuilt before any replay — a `429`/`503` retry or a `401` token refresh — because a `FormData` is a stream that Dio reads once and refuses to read again. A JSON `content-type` is stripped for multipart bodies, including one you pass yourself.
* **`ApiServices.reset()`** — clears the singleton, config, and loader callbacks. Fixes `setLogging` being silently a no-op after the first `instance()` call, and gives tests a clean slate.
* **`package:baaba_api_handler/testing.dart`** — ships `FakeApiServices`, an in-memory double with stubbing and call recording, so consumers can test repositories without mocking Dio. An unstubbed endpoint throws a `StateError` naming it rather than quietly returning null.
* **`Failure.data`, `Failure.statusCode`, `Failure.validationErrors`, `Failure.requestOptions`** — the raw body, the literal HTTP status (`code` collapses anything unrecognised to `defaultError`), per-field errors parsed from a `{"errors": {...}}` body, and the request that failed. `requestOptions` is excluded from equality: it is context about where a failure came from, not part of what the failure is.
* `package:baaba_api_handler/baaba_api_handler.dart` as the conventional entrypoint. The old `ts_api_handler.dart` import still works.

## 1.4.0

* Added `ApiLogOptions` — the consuming app now controls what the console logger prints: `enabled`, `request`, `requestHeader`, `requestBody`, `responseHeader`, `responseBody`, `error`, `maxWidth`, `compact`, and `logPrint`. Previously the logger was hardcoded to `requestBody: true` with no way to change it. Includes an `ApiLogOptions.disabled()` constructor and `copyWith`.
* Added `logging` parameter to `ApiServices.configure()`, defaulting to `const ApiLogOptions()` — same output as before, so existing callers see no change.
* Added `ApiServices.setLogging(ApiLogOptions)` — same control for apps that don't use token auth. Must be called before the first `ApiServices.instance()`, since the Dio client and its logger are built once and cached.
* Release builds are unaffected: the logger is still never attached when `kReleaseMode` is true.

## 1.3.1

* Added support for the `detail` key in API error responses (RFC 7807), falling back to it if `message` is missing but prioritizing it over `error`.

## 1.3.0

* Added `ApiServices.download()` — streams a file response directly to disk (`savePath`) instead of loading it into memory, with `onReceiveProgress`, `cancelToken`, and `deleteOnError` support. Goes through the same connectivity check and loader plumbing as the other HTTP methods.
* Added `refreshTimeout` parameter to `ApiServices.configure()` (default 30 seconds). Bounds how long a request that 401s while another refresh is already in flight will wait for that refresh before giving up and failing with the original error.
* `TokenRefreshInterceptor`: requests that 401 while a refresh is already in progress now wait for that refresh to finish and retry with the fresh token, instead of failing immediately. Previously only the first request in a concurrent-401 burst would succeed; the rest errored out just for losing the race.
* `NetworkRetryInterceptor` now only auto-retries idempotent methods (`GET`, `HEAD`, `OPTIONS`, `PUT`, `DELETE`). `POST`/`PATCH` are no longer retried on transient timeouts/connection errors, since the server may have already processed the request and a blind retry could duplicate the side effect.
* Added `maxAge` parameter to `ApiCacheHelper.getCacheData()` — if the cached entry is older than `maxAge`, it's treated as a miss (the stale entry is cleared and `null` returned) instead of returning stale data. Omit it to keep the previous behaviour of returning cached data regardless of age.
* Bumped `dio` to `^5.10.0`, `pretty_dio_logger` to `^1.4.0`, `internet_connection_checker_plus` to `^3.1.1`, `fpdart` to `^1.2.0`, `equatable` to `^2.1.0`, and `sqflite_common_ffi` (dev) to `^2.4.0+3`.

## 1.2.0

* Added `ApiServices.configureLoader({onShow, onHide})` — a global, framework-agnostic loading indicator shown automatically around every request (success, failure, and thrown exceptions all covered), so callers no longer need a per-screen `isLoading` flag. `onShow`/`onHide` are plain callbacks (e.g. `Get.dialog`/`Get.back` for GetX, or `showDialog`/`Navigator.pop` with a global key) — the package has no UI dependency.
* Added `showLoader` parameter (default `true`) to `get`/`post`/`put`/`patch`/`delete` to opt a specific request out of the loader.
* Concurrent requests share one indicator via reference counting: `onShow` fires only for the first in-flight request, `onHide` only once every in-flight request has finished.

## 1.1.0

* **Breaking:** `ErrorSource` enum variants renamed from `snake_case` to `camelCase` (e.g. `no_content` → `noContent`, `bad_request` → `badRequest`). Update any `switch` or direct references in your code.
* Added `bypassConnectivityCheck` parameter to `ApiServices.configure()` for staging/internal environments where connectivity probes fail due to proxies or firewalls.
* Added `ApiServices.setConnectivityCheck({bool enabled})` — controls the connectivity check independently of token auth configuration.
* `cancelRequest()` now cancels **all** in-flight requests (previously only the most recent). All active `CancelToken`s are tracked in a `Set` and cancelled together.
* Extended `ResponseCode` and `ErrorSource` with six new HTTP status codes: `created` (201), `requestTimeout` (408), `conflict` (409), `unprocessableEntity` (422), `tooManyRequests` (429), `badGateway` (502).
* Fixed `ResponseCode.noContent` raw value from 201 to 204.
* `ResponseCode` refactored to use inline integer values (`ResponseCode.success(200)` style) — no longer requires an extension for `.value`.
* `ResponseStrings` rewritten with cleaner, user-facing error messages.
* `ErrorHandler` no longer implements `Exception`.

## 1.0.7

* Added `TokenRefreshInterceptor` for automatic token refresh on 401 responses.
* Added `NetworkRetryInterceptor` for automatic retry on transient network failures.
* Added `ApiServices.configure()` static method for setting up token-based authentication.
* Added `headerBuilder` parameter to `ApiServices.configure()` for customising auth headers per request.
* Added `onSendProgress`, `onReceiveProgress`, and `CancelToken` parameters to all request methods.
* Re-exported `Response` and `CancelToken` from Dio, and `APICacheDBModel` from api_cache_manager — no separate imports needed.

## 1.0.6

* Added `SERVICE_NOT_AVAILABLE` (503) to `ResponseCode` and error handling.
* Improved error message extraction from API response body (`message` and `error` keys).

## 1.0.5

* Updated readme documentation and bumped version.

## 1.0.4

* Added license information.

## 1.0.3

* Updated package structure and internal functionality.

## 1.0.2

* Fixed multipart request method naming.
* Fixed incorrect MIME types in multipart requests.

## 1.0.1

* Added multipart request support.
* Updated dependencies.

## 1.0.0

* Initial release.
* HTTP methods: GET, POST, PUT, PATCH, DELETE.
* API response caching via `ApiCacheHelper`.
* Network connectivity checks before each request.
* Structured error handling with `Failure`, `ErrorSource`, and `ResponseCode`.
