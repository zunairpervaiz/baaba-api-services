## 3.1.0

### Fixed

* **`maxConcurrentRequests` deadlocked a token refresh made through the client.** A request that `401`'d held its slot while awaiting the refresh, so a refresh request sent through `ApiServices` — the shape the README shows — queued behind the very requests waiting on it. A cap of `1` hung forever; a cap of _n_ with _n_ concurrent `401`s stalled until `refreshTimeout` and then failed them all. Requests made from inside `onTokenRefresh` now bypass the cap.
* **`cancelRequest()` and `reset()` missed requests still in the connectivity probe.** The token was registered only once the probe had passed, so a request cancelled — or orphaned by a logout's `reset()` — during the probe went out anyway, and could write the previous user's response into the cache. Tokens are now registered for the request's whole life, and a client discarded by `reset()` sends nothing further.
* **A `CancelToken` shared by several requests escaped `cancelRequest()`.** The first request to finish unregistered it for all the others.
* **A `GET` body was not part of its cache key.** Two searches differing only in their body shared an entry, so the second was answered with the first's results. A `GET` with a body that cannot be encoded is no longer cached.
* **A plain-text caller could be served a JSON caller's cached `Map`** for the same url, and vice versa. `responseType: plain` responses are cached under their own key.
* **Duplicate cache rows froze an entry for good.** Once a key had two rows — from a second isolate, or left over from 1.x — every write inserted another and every read returned the oldest, so the cache served its first-ever response forever. Each write now clears the key first, which heals it.
* **An expired entry's cleanup could delete a fresh write** for the same key that landed in between. The cleanup now runs in that key's write queue, and only removes the row it judged stale.
* **A late `401` could still trigger a second refresh** when the token string was unchanged across the refresh, or read stale while it landed. Each request now records the refresh generation it was sent under, which is checked synchronously.
* **A broken loader callback broke the request.** A throwing `onShow` — `navigatorKey.currentContext!` before the navigator mounts, say — escaped as an exception and left the loader count stuck so it never showed again; a throwing `onHide` replaced the request's result. Both are now contained, like observer callbacks.
* **A throwing `onRefreshFailed` replaced the `401`.** Code checking for `ErrorSource.unauthorized` saw a generic error instead.
* **A huge `Retry-After` retried immediately.** Delta-seconds large enough to overflow `Duration` wrapped negative and slipped under the `maxDelay` clamp.
* **A device clock set backwards stretched the connectivity cache** until the clock caught up, reporting "connected" from a stale probe.
* **`maxConcurrentRequests: 0` queued every request forever.** It is now rejected by an assert, and treated as `1` in release builds.

* **`upload()` sent only the last of several files sharing a field.** The `FormData` was built from a map literal, so `UploadFile`s with the same `field` — a gallery's `images`, say — were duplicate keys and all but the last were silently dropped. Each file is now appended as its own entry.
* **A throwing `ApiConfig.isSuccess` escaped as an exception.** A predicate written for an envelope body, such as `r.data['success'] == true`, threw on a `204`'s `null` body, breaking the guarantee that no exception crosses the API boundary. A throw now counts as a rejection (it fails closed, like `AuthConfig.sendTokenTo`) and routes through `onRejected` as usual.
* **A late `401` started a second, redundant token refresh.** A request sent with the old token whose `401` arrived only after another request's refresh had finished saw no refresh in progress and refreshed again — against a backend that rotates refresh tokens, a refresh that can fail and sign the user out. A `401` for a token that has since been replaced now replays with the current token instead.
* **`ApiServices.reset()` left the discarded client's requests running.** On logout, one that finished afterwards could write the previous user's response back into a cache that had just been cleared. `reset()` now cancels them; they complete with `ErrorSource.cancel`.
* **De-duplication could hand a caller another caller's response.** The in-flight key ignored headers and `responseType`, so a `GET` sent with `Accept-Language: ur` could receive the response to a concurrent English one, and a `responseType: bytes` caller could receive a decoded map. Bodies were keyed by `toString()`, so two different model objects without their own `toString` — both `Instance of 'Query'` — were treated as one request. A follower's `onSendProgress`/`onReceiveProgress` never fired, since only the originator's callbacks reach Dio. Headers (case-insensitively) and `responseType` are now part of the key, bodies are compared as JSON (an unencodable body is never collapsed), and a call with a progress callback goes out alone.
* **`cancelRequest()` did not reach a request queued behind `maxConcurrentRequests`.** The queue sits outside Dio, so Dio's cancellation never saw it: a cancelled request waited for a free slot before failing, holding the loader the whole time — behind a long upload, the whole upload. It now fails with `ErrorSource.cancel` immediately, never reaches the network, and gives its place in the queue to the next request.
* **`ApiServices.reset()` during a request broke the loader permanently.** The in-flight request's release took the zeroed count to `-1`, so the next request's increment landed on `0` and `onShow` never fired again. Releases from before a `reset()` are now ignored.
* **Binary responses were cached as JSON.** A `responseType: bytes` body was stored as a JSON list and served back as `List<dynamic>` instead of `Uint8List`; and since the cache key has no response type, a `bytes` caller could be served a map cached by a JSON caller of the same url. `bytes` and `stream` requests now bypass the cache.
* **`cacheMaxBytes` could evict live entries for space that was already free.** Entries deleted by `clearCache` before the eviction index was loaded, or expired by `cacheMaxAge`, stayed in the index and kept counting against the cap. Sizes were also measured in UTF-16 code units rather than bytes, undercounting non-ASCII bodies up to threefold.
* **An HTML error page became `Failure.message`.** A gateway's `502`/`504` page (nginx, Cloudflare, a load balancer) was surfaced verbatim, markup and all. HTML bodies now fall back to the generic message for the status. A boolean such as `{"error": true}` is no longer reported as the message `"true"`, and an empty `message` no longer hides a later `detail` or `error`.
* **A failed token replay reported the wrong error.** When the replay after a successful refresh threw anything other than a `DioException` — `getToken()` failing, say — it fell into the refresh's own `catch`, which completed the refresh completer a second time. The request failed with `Bad state: Future already completed` in place of the real cause. The replay now handles its own errors and the original is preserved.

### Changed (test double)

* **`FakeApiServices` now builds failures the way the real client does.** `stubFailure` maps the status (`401` → `ErrorSource.unauthorized`) and reads the body's message, where it always produced `badRequest` with the generic text. `stubJson` with a non-`2xx` status is a failure, as Dio makes it. `ApiConfig.isSuccess` applies to stubbed responses. A consumer test that asserted the old, unrealistic values will need updating — it was passing against behaviour production does not have.

## 3.0.0

See `MIGRATION.md` for upgrade steps. Most apps need only the first item.

### ⚠️ Breaking changes

* **Requires `equatable` 3.** `Failure` extends `Equatable`, so this package and your app must agree on its major version. If your app pins `equatable: ^2.x`, raise it to `^3.0.0`.
* **The deprecated 1.x configuration methods are removed.** `ApiServices.configure()`, `setConnectivityCheck()` and `setLogging()` were deprecated in 2.0.0 and scheduled for removal in this release. Use `ApiServices.init(ApiConfig(...))`; the mapping is in `MIGRATION.md`.
* **`HttpMethod` gained `head` and `options`.** A `switch` that covers every `HttpMethod` value no longer compiles until you add the two cases or a wildcard.
* **`ApiServices` gained `head()` and `options()`.** Code that implements `ApiServices` directly, instead of using `FakeApiServices`, must add them.

### Changed

* Minimum `dio` is now `5.11.0`, and minimum `internet_connection_checker_plus` is now `3.1.2`.
* Added `repository` and `issue_tracker` to the pubspec.

### Fixed

* **The auth token was sent to every host the client talked to.** `TokenRefreshInterceptor` attached it with no host check, while `ApiConfig.baseUrl` documents absolute endpoints as a supported way to reach a CDN or third party from the same client — so a session token travelled to whoever the caller named. It also broke the most common reason to use an absolute endpoint: S3 rejects a presigned URL request that also carries an `Authorization` header. The token now goes only to the `baseUrl` host by default, overridable with `AuthConfig.sendTokenTo`. A `401` from an unscoped host no longer triggers a refresh either, so a third party's `401` cannot cascade into `onRefreshFailed` and sign the user out.
* **A `401` arriving during a token replay triggered a second, redundant refresh.** `TokenRefreshInterceptor` returned the replayed request without awaiting it, so the `finally` that clears `_isRefreshing` ran while the replay was still in flight. Any request that `401`'d in that window saw no refresh in progress and started its own — the stampede the interceptor exists to prevent, and a real hazard against a backend that rotates refresh tokens. The replay is now awaited.
* **A project-wide `defaultCachePolicy` cached writes.** `CachePolicy` is documented as a `get`/`getAs`-only contract, and only those methods expose the argument — but `ApiConfig.defaultCachePolicy` applies to every request that does not name one, which is every `post`, `put`, `patch` and `delete` there is. Setting it project-wide meant a repeated `POST /orders` was answered from the cache and never reached the server. Cache keys carry no method or body either, so a `POST`, `PUT`, `PATCH` and `DELETE` on one path all shared a single entry, and a `POST` response could be served to a later `GET`. Caching is now restricted to `GET` where the policy is resolved, rather than relying on the method signatures to enforce it.
* **`ApiConfig.defaultHeaders` was documented backwards.** The dartdoc claimed a request's own `headers` *replace* the defaults; they are merged over them, which is what the README always said and what the code always did.

### Added

* **`ApiConfig.interceptors`.** Your own Dio interceptors, for anything that needs to modify a request rather than just watch it — correlation ids, tenant headers, request signing, a fixture router for local development. Inserted after auth (so a signer sees the `Authorization` header) and before retry and the logger (so replays re-run them and the log shows their work). `Interceptor`, `InterceptorsWrapper`, `QueuedInterceptor`, the three handler types, `DioException`, `DioExceptionType` and `HttpClientAdapter` are now exported, so writing one needs no direct `dio` dependency — `HttpClientAdapter` in particular was already referenced by public config but was not on the surface.
* **`ApiConfig.maxConcurrentRequests`.** Caps requests in flight, queueing the rest in the order they were made. Firing twenty requests at once saturates a mobile connection pool and reliably trips server-side rate limiting that `retry` then has to clean up. The cap governs real network calls — cache hits and de-duplicated callers do not consume a slot — and a queued request stays cancellable. Unset by default, which is unlimited.
* **`responseType` on every request method.** Fetch bytes or plain text instead of decoded JSON — an image into memory, or a CSV export — without dropping to raw Dio. `ResponseType` is re-exported.
* **`head()` and `options()`.** `RetryPolicy.idempotentMethods` already listed `HEAD` and `OPTIONS`, but neither was reachable through the public API. `HttpMethod` gained matching variants, and `HttpMethodExtension` (so `HttpMethod.get.value` works) is now exported.
* **Cancellation by tag.** Requests accept a `tag`, and `cancelRequest(tag: 'feed')` cancels only those — previously it was all-or-nothing, so one screen tearing down aborted requests belonging to screens still on the stack. Omitting the tag still cancels everything. A tagged request opts out of de-duplication, for the same reason a caller-supplied `CancelToken` does.
* **`ApiConfig.onRejected`.** Builds the `Failure` for a `2xx` that `isSuccess` rejected, so an API reporting its own error codes in the body no longer collapses to a generic `badRequest`. Returning `null` falls back to the previous behaviour.
* **`ApiConfig.connectivityProbe`.** Replaces the default third-party ping with your own check — a health endpoint, typically. The default is blocked on some corporate networks and says nothing about whether your API is reachable, and until now the only alternative was disabling the check wholesale.
* **`ApiConfig.cacheMaxEntries` and `cacheMaxBytes`.** The cache was unbounded: every distinct url and query combination added an entry nothing removed, and `cacheMaxAge` only discards a stale entry when something reads it. Past either cap the oldest entries are now evicted. Both default to `null`, leaving the cache unbounded exactly as before.

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
