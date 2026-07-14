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
