# baaba_api_handler

A typed, functional HTTP client for Flutter. Wraps [Dio](https://pub.dev/packages/dio) with `Either`-based error handling, automatic token refresh, configurable retries, response caching, and a built-in test double.

No exceptions cross the API boundary — every method returns `Either<Failure, T>`.

```dart
final result = await api.getAs<User>(endpoint: '/users/1', parser: User.fromJson);

result.fold(
  (failure) => emit(ErrorState(failure.message)),
  (user)    => emit(LoadedState(user)),
);
```

> **Upgrading from 1.x?** See [MIGRATION.md](MIGRATION.md). Your existing code keeps working; three things can break you, all listed there.

## Table of Contents

- [Installation](#installation)
- [Setup](#setup)
- [Making requests](#making-requests)
  - [Typed responses](#typed-responses)
  - [Request parameters](#request-parameters)
  - [Uploads](#uploads)
  - [Downloads](#downloads)
  - [Cancellation](#cancellation)
- [Handling failures](#handling-failures)
  - [Validation errors](#validation-errors)
  - [Success that isn't](#success-that-isnt)
- [Authentication](#authentication)
- [Caching](#caching)
- [Retries](#retries)
- [Observability](#observability)
- [Loading indicator](#loading-indicator)
- [Certificate pinning and proxies](#certificate-pinning-and-proxies)
- [Logging](#logging)
- [Testing](#testing)
- [Configuration reference](#configuration-reference)

---

## Installation

```yaml
dependencies:
  baaba_api_handler: ^2.0.0
```

```dart
import 'package:baaba_api_handler/baaba_api_handler.dart';
```

> `Response`, `CancelToken`, `FormData` (Dio) and `APICacheDBModel` are re-exported from this single import — you don't need `dio` or `api_cache_manager` as direct dependencies.

---

## Setup

Call `init` once at app startup, before any request:

```dart
void main() {
  ApiServices.init(ApiConfig(
    baseUrl: 'https://api.example.com',
    auth: AuthConfig(
      getToken: () => storage.read(key: 'access_token'),
      onTokenRefresh: () => authRepository.refresh(),
      onRefreshFailed: () => authController.logout(),
    ),
  ));
  runApp(const MyApp());
}
```

Every field is optional. `ApiServices.init(const ApiConfig())` gives a plain client with sane timeouts and no auth, and skipping `init` entirely also works — `instance()` builds a default client on first use.

Environments usually differ in a field or two, so build one base config and `copyWith` the rest:

```dart
const base = ApiConfig(connectTimeout: Duration(seconds: 20));

// staging: internal network, connectivity probe blocked by the proxy
ApiServices.init(base.copyWith(
  baseUrl: 'https://staging.example.com',
  bypassConnectivityCheck: true,
));
```

`ApiServices.reset()` clears the singleton, config, and loader callbacks — useful on logout, and in test `tearDown`.

---

## Making requests

```dart
final api = ApiServices.instance();

final result = await api.get(endpoint: '/users', params: {'page': 1});

result.fold(
  (failure) => print(failure.message),
  (response) => print(response.data),
);
```

`get`, `post`, `put`, `patch`, `delete`, `upload`, and `download` are available. With `baseUrl` set, endpoints are relative; an absolute endpoint is used as-is, so hitting a CDN or third-party host from the same client works fine.

### Typed responses

Each verb has an `*As<T>` variant that takes a `parser` and hands back the deserialized object, removing the `fold` → `fromJson` → try/catch block from every repository method:

```dart
final user = await api.getAs<User>(endpoint: '/users/1', parser: User.fromJson);
// Either<Failure, User>
```

For lists, `listParser` wraps a single-object parser:

```dart
// [{"id": 1}, {"id": 2}]
await api.getAs<List<User>>(endpoint: '/users', parser: listParser(User.fromJson));

// {"data": [{"id": 1}], "meta": {...}}
await api.getAs<List<User>>(
  endpoint: '/users',
  parser: listParser(User.fromJson, key: 'data'),
);
```

If the parser throws, you get a `Failure` with `ErrorSource.parseError` and the raw body in `failure.data` — the exception never reaches you.

### Request parameters

Shared by every HTTP method:

| Parameter | Type | Description |
| --- | --- | --- |
| `endpoint` | `String` | Path, relative to `baseUrl`, or an absolute URL. |
| `data` | `Object?` | Request body. |
| `params` | `Map<String, dynamic>?` | Query parameters. |
| `headers` | `Map<String, String>?` | Replaces the default `application/json` headers for this request. |
| `receiveTimeout` | `Duration?` | Overrides the configured receive timeout. |
| `sendTimeout` | `Duration?` | Overrides the configured send timeout. |
| `cancelToken` | `CancelToken?` | Cancels this specific request. |
| `onSendProgress` | `ProgressCallback?` | Upload progress. |
| `onReceiveProgress` | `ProgressCallback?` | Download progress. |
| `showLoader` | `bool` | Opt this request out of the global loader. Defaults to `true`. |

`get` and `getAs` additionally accept `cachePolicy`, `cacheMaxAge`, and `dedupe` — see [Caching](#caching).

### Uploads

```dart
final result = await api.upload(
  endpoint: '/profile/avatar',
  fields: {'userId': '42'},
  files: [UploadFile.fromPath(field: 'avatar', path: picked.path)],
  onSendProgress: (sent, total) => progress.value = sent / total,
);
```

Use `UploadFile.fromBytes` on web, where a picked file has no filesystem path:

```dart
UploadFile.fromBytes(field: 'avatar', bytes: pickedBytes, filename: 'avatar.png')
```

`contentType` is inferred from the filename when omitted. A JSON `content-type` is never sent with a multipart body, even if you pass one in `headers` — it would replace the `multipart/form-data` type Dio generates, boundary included.

Uploads default to `POST`; pass `method:` for an API that expects `PUT` or `PATCH`.

A timeout on an upload is never retried — the server may already have stored the file. A `429` or `503` is, because the server said it did not process the request, and so is a replay after a `401` token refresh, which matters for an upload long enough to outlive its token. In both cases the multipart body is rebuilt before resending: it is a stream, read once, and Dio throws if you hand it the consumed one.

### Downloads

Streams the response straight to disk rather than loading it into memory:

```dart
final dir = await getApplicationDocumentsDirectory();

final result = await api.download(
  endpoint: '/files/report.pdf',
  savePath: '${dir.path}/report.pdf',
  onReceiveProgress: (received, total) => print('${received / total * 100}%'),
);
```

### Cancellation

`cancelRequest()` cancels every in-flight request:

```dart
@override
void onClose() {
  api.cancelRequest(cancellationReason: 'Screen closed');
  super.onClose();
}
```

For a single request, pass your own `CancelToken`.

---

## Handling failures

`Failure` carries a user-facing `message`, a mapped `code`, and the raw response:

| Field | Description |
| --- | --- |
| `message` | Human-readable. Extracted from the body's `message`, `detail`, or `error` key, falling back to a generic string for the status. |
| `errorType` | `ErrorSource` — semantic enum (`notFound`, `unauthorized`, `parseError`, …). |
| `code` | `ResponseCode` — enum with an integer `value`. Collapses unrecognised statuses to `defaultError`. |
| `statusCode` | The literal HTTP status, e.g. `418`. `null` for failures that never reached the server. |
| `data` | The raw response body. `null` for offline, timeout, and cancellation. |
| `validationErrors` | Per-field errors parsed from an `errors` object. `null` when absent. |
| `requestOptions` | The request that failed — method, path, headers. `null` when none was built. Excluded from equality. |

### Validation errors

For a `422` body like `{"message": "Validation failed", "errors": {"email": ["already taken"]}}`:

```dart
result.fold(
  (failure) {
    final fields = failure.validationErrors;
    if (fields != null) {
      emailError.value = fields['email']?.first;
      nameError.value = fields['name']?.first;
    } else {
      showSnackBar(failure.message);
    }
  },
  (user) => ...,
);
```

### Success that isn't

Some APIs answer `200 OK` with `{"success": false, "message": "..."}`. Without help, those land in `Right` and every caller has to re-check the body. `isSuccess` routes them to `Failure` instead, pulling the message out the same way a real error response would:

```dart
ApiServices.init(ApiConfig(
  isSuccess: (response) {
    final data = response.data;
    return data is! Map || data['success'] != false;
  },
));
```

---

## Authentication

`AuthConfig` attaches a token to every request and refreshes it on `401`:

```dart
ApiServices.init(ApiConfig(
  auth: AuthConfig(
    getToken: () => storage.read(key: 'access_token'),
    onTokenRefresh: () => authRepository.refresh(),   // true on success
    onRefreshFailed: () => authController.logout(),
    refreshTimeout: const Duration(seconds: 20),
  ),
));
```

A burst of concurrent `401`s — the usual shape of a token expiring — all wait on one refresh and retry, rather than only the first succeeding. `refreshTimeout` bounds that wait, so the pathological case where the refresh endpoint itself `401`s surfaces the original error instead of deadlocking.

By default the token goes out as `Authorization: Bearer <token>`. `headerBuilder` changes that:

```dart
AuthConfig(
  getToken: () => storage.read(key: 'token'),
  onTokenRefresh: () => authRepo.refresh(),
  headerBuilder: (token) => {
    'Authorization': 'Token $token',
    'X-Tenant-Id': 'my-org',
  },
)
```

Omit `auth` entirely for an unauthenticated client; `401`s then surface as an ordinary `Failure`.

---

## Caching

Opt in per request. The default, `CachePolicy.networkOnly`, ignores the cache entirely.

```dart
final result = await api.get(
  endpoint: '/products',
  cachePolicy: CachePolicy.networkFirst,
  cacheMaxAge: const Duration(minutes: 10),
);

result.fold(
  (failure) => showError(failure.message),
  (response) {
    if (response.isFromCache) showBanner('Offline — showing saved data');
    render(response.data);
  },
);
```

| Policy | Behaviour |
| --- | --- |
| `networkOnly` | Never reads or writes the cache. The default. |
| `cacheFirst` | Fresh hit → return it, no network. Miss or stale → network, then store. |
| `networkFirst` | Network → store and return. On failure → fall back to the cache; if nothing is cached, the original failure is returned unchanged. |
| `cacheOnly` | Hit → return. Miss → `Failure` with `ErrorSource.cacheError`. Never touches the network. |

### Project-level control

Not every app should cache. Two levers on `ApiConfig`:

```dart
// Nothing may cache, whatever a call site asks for. The database is never
// even opened. For apps where "no response body is written to disk" is a
// requirement rather than a preference.
ApiServices.init(const ApiConfig(cacheEnabled: false));

// Or the opposite: make caching the norm without annotating every call.
// Individual calls can still opt out with `cachePolicy: CachePolicy.networkOnly`.
ApiServices.init(const ApiConfig(defaultCachePolicy: CachePolicy.networkFirst));
```

`cacheEnabled: false` overrides both `defaultCachePolicy` and any explicit `cachePolicy` argument, so one stray call site can't undo it. Leaving the defaults alone also results in no caching — but that relies on every call site getting it right, and this doesn't.

Only successful (`2xx`) responses are stored, and caching is best-effort — a body that will not encode is skipped rather than failing the request. Query parameters are part of the cache key, so `?page=1` and `?page=2` are separate entries.

> **Cached entries are not scoped per user.** Call `ApiCacheHelper.instance.clearAllCache()` on logout, or the next user will read the previous one's responses.

`ApiCacheHelper` is also usable directly, for caching things the HTTP layer doesn't own:

```dart
final cache = ApiCacheHelper.instance;

await cache.setCacheData('user_prefs', jsonEncode(prefs));
final entry = await cache.getCacheData('user_prefs', maxAge: const Duration(days: 1));
await cache.clearCache('user_prefs');
await cache.clearAllCache();
```

`getCacheData` returns `null` on a miss or when the entry is older than `maxAge`.

### De-duplication

Two identical `GET`s in flight at the same time share one network call — the common case being several widgets on one screen asking for the same resource. Pass `dedupe: false` to opt out. It is skipped automatically when you supply your own `CancelToken`, since cancelling one caller must not cancel the other.

De-duplication is not a cache: sequential requests each hit the network.

---

## Retries

Transient failures are retried automatically. `RetryPolicy` controls the details:

```dart
ApiServices.init(const ApiConfig(
  retry: RetryPolicy(maxRetries: 5, baseDelay: Duration(seconds: 1)),
));

// or turn it off entirely
ApiServices.init(const ApiConfig(retry: RetryPolicy.disabled()));
```

| Field | Default | Description |
| --- | --- | --- |
| `maxRetries` | `3` | Attempts after the first. `0` disables retries. |
| `baseDelay` | `500ms` | Attempt _n_ waits up to `baseDelay * 2^(n-1)`. |
| `maxDelay` | `30s` | Ceiling on any single wait. |
| `useJitter` | `true` | Spread retries randomly across the backoff window. |
| `respectRetryAfter` | `true` | Honour the server's `Retry-After` header. |
| `retryableStatusCodes` | `{408, 429, 500, 502, 503, 504}` | Which statuses are worth retrying. |
| `retryIf` | `null` | Final veto: `(error, attempt) => bool`. |

**What gets retried, and why it depends on the method.** Transport errors (timeouts, connection failures) are retried for idempotent methods only — if the server already processed a `POST` before the timeout, repeating it could create the same order twice. Status codes split the same way: `429` and `503` mean the server explicitly did *not* process the request, so those are safe for any method; `408`, `500`, `502`, and `504` are ambiguous and stay gated on idempotency.

`Retry-After` is understood in both permitted forms — delta-seconds and HTTP-date — and clamped to `maxDelay`. Backoff uses full jitter, so a burst of requests that fail together don't all retry in lockstep and hammer a recovering server.

---

## Observability

One hook for every request, response, and failure:

```dart
class SentryObserver extends ApiObserver {
  @override
  void onFailure(Failure failure, RequestOptions? options) {
    Sentry.captureMessage(
      '${options?.method} ${options?.path} → ${failure.code.value}',
      level: SentryLevel.warning,
    );
  }
}

ApiServices.init(ApiConfig(observer: SentryObserver()));
```

`onResponse` and `onFailure` fire exactly once per call you made, including for failures Dio never produces an exception for — offline short-circuits, parse errors, and bodies rejected by `isSuccess`. `onRequest` fires per network attempt, so a retried request reports more than once.

An observer that throws can never break a request.

---

## Loading indicator

Register a global indicator and every request shows it automatically:

```dart
// GetX
ApiServices.configureLoader(
  onShow: () => Get.dialog(const LoadingDialog(), barrierDismissible: false),
  onHide: () => Get.back(),
);

// Navigator with a global key
ApiServices.configureLoader(
  onShow: () => showDialog(
    context: navigatorKey.currentContext!,
    barrierDismissible: false,
    builder: (_) => const LoadingDialog(),
  ),
  onHide: () => navigatorKey.currentState!.pop(),
);
```

The package has no UI dependency — these are plain closures. Calls are reference-counted, so concurrent requests share one indicator: `onShow` fires for the first, `onHide` only once every in-flight request has finished, whether it succeeded, failed, or threw. Pass `showLoader: false` to opt a request out, e.g. background polling.

---

## Certificate pinning and proxies

Supply your own `HttpClientAdapter`. The package deliberately ships no implementation: the `dart:io`-based adapters don't exist on web, and bundling one would cost the package its platform neutrality.

```dart
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/io.dart';

const _pinnedSha256 = 'AA:BB:CC:...';

ApiServices.init(ApiConfig(
  httpClientAdapter: IOHttpClientAdapter(
    createHttpClient: () => HttpClient()
      ..badCertificateCallback = (cert, host, port) {
        final fingerprint = sha256.convert(cert.der).toString();
        return fingerprint == _pinnedSha256;
      },
  ),
));
```

The same hook routes traffic through Charles or Proxyman while debugging:

```dart
httpClientAdapter: IOHttpClientAdapter(
  createHttpClient: () => HttpClient()
    ..findProxy = (uri) => 'PROXY 192.168.1.10:8888'
    ..badCertificateCallback = (_, __, ___) => true,   // debug builds only
),
```

---

## Logging

`PrettyDioLogger` is attached outside release builds only. `ApiLogOptions` controls what it prints:

```dart
ApiServices.init(ApiConfig(
  logging: ApiLogOptions(
    requestHeader: true,
    responseHeader: true,
    maxWidth: 120,
    logPrint: (line) => myLogger.debug(line.toString()),
  ),
));
```

| Field | Default | Description |
| --- | --- | --- |
| `enabled` | `true` | Master switch. `ApiLogOptions.disabled()` turns everything off. |
| `request` | `true` | Log the request line. |
| `requestHeader` | `false` | Log request headers. |
| `requestBody` | `true` | Log the request body. |
| `responseHeader` | `false` | Log response headers. |
| `responseBody` | `true` | Log the response body. |
| `error` | `true` | Log errors. |
| `maxWidth` | `90` | Wrap width. |
| `compact` | `true` | Compact JSON output. |
| `trimBase64` | `false` | Collapse base64 blobs — see below. |
| `logPrint` | `debugPrint` | Where lines go. |

Release builds never attach a logger, whatever this says.

### Base64 in log output

An API that returns photographs or fingerprints inline will drown your console. The logger wraps every value at `maxWidth` and emits one line per ~78 characters, so a single 400 KB image becomes several thousand lines — and the request that caused them has scrolled away long before the body finishes.

`trimBase64` collapses those runs:

```dart
ApiServices.init(const ApiConfig(
  logging: ApiLogOptions(trimBase64: true),
));
```

```
║      "caseNo": "FIR-2026-000148-ISB",
║      "data": iVBORw0KGgoAAAANSUhEUg…
║      …[412903 base64 chars elided]
║      "capturedAt": "2026-08-13T09:14:22Z"
```

**It filters lines, not fields** — by the time the logger calls `logPrint` it has already flattened the body, so the test is a shape test: a run of the base64 alphabet long enough that it cannot be an id or a status. Everything else passes through byte for byte, so a `detail` string, a case number, and a stack trace all read exactly as they did.

Off by default, because it rewrites the log stream and that should be your choice.

If your API returns long reference codes that the default would swallow, or you want the trimmer in front of your own sink, build it yourself — `logPrint` is a sink, not a switch:

```dart
ApiServices.init(ApiConfig(
  logging: ApiLogOptions(
    logPrint: Base64LogTrimmer(sink: myLogger.debug, minRunLength: 60).call,
  ),
));
```

| Parameter | Default | Description |
| --- | --- | --- |
| `sink` | required | Where surviving lines go. |
| `keptChars` | `24` | Characters of the blob kept before the ellipsis. |
| `minRunLength` | `40` | Shortest base64 run treated as a blob rather than an id. |

Give each client its own instance — a trimmer holds the running count of elided characters.

---

## Testing

`package:baaba_api_handler/testing.dart` ships an in-memory `FakeApiServices`, so you can test a repository or controller without mocking Dio:

```dart
import 'package:baaba_api_handler/testing.dart';

late FakeApiServices api;

setUp(() {
  api = FakeApiServices();
  api.stubJson(HttpMethod.get, '/users/1', {'id': 1, 'name': 'Ada'});
});

test('loads the user', () async {
  final user = await UserRepository(api).find(1);

  expect(user.name, 'Ada');
  expect(api.recordedCalls.single.endpoint, '/users/1');
});

test('surfaces a validation error', () async {
  api.stubFailure(
    HttpMethod.post,
    '/users',
    statusCode: 422,
    body: {'errors': {'email': ['already taken']}},
  );

  final result = await api.post(endpoint: '/users', data: {...});

  result.fold(
    (f) => expect(f.validationErrors!['email'], ['already taken']),
    (_) => fail('expected a failure'),
  );
});
```

| Method | Purpose |
| --- | --- |
| `stubJson(method, endpoint, body)` | Queue a successful response. |
| `stubFailure(method, endpoint, ...)` | Queue a failure, from a `Failure` or a status/body. |
| `stubOffline(method, endpoint)` | Queue the no-connection short-circuit. |
| `stub(method, endpoint, either)` | Queue a raw `Either` for full control. |
| `recordedCalls` | Every call made, with endpoint, body, params, headers, files. |
| `cancellations` | Reasons passed to `cancelRequest`. |
| `reset()` | Clear stubs and history. |

Stub the same endpoint more than once to script a sequence — each call consumes one entry and the last repeats, which makes "fails, then succeeds on retry" easy to set up. Calling an endpoint you didn't stub throws a `StateError` naming it, so an unexpected call fails loudly instead of quietly returning null.

Add `ApiServices.reset()` to `tearDown` so configuration doesn't leak between tests.

---

## Configuration reference

Every field on `ApiConfig`:

| Field | Default | Description |
| --- | --- | --- |
| `baseUrl` | `null` | Prefix for relative endpoints. |
| `connectTimeout` | `30s` | Wait for the connection to be established. |
| `receiveTimeout` | `30s` | Wait between response chunks. |
| `sendTimeout` | `30s` | Wait while sending the body. |
| `defaultHeaders` | `{}` | Merged into every request. |
| `bypassConnectivityCheck` | `false` | Skip the pre-flight internet check — needed behind proxies that block the probe. |
| `connectivityCacheTtl` | `5s` | How long a positive connectivity result is reused. |
| `logging` | `ApiLogOptions()` | Console logger settings. |
| `retry` | `RetryPolicy()` | How transient failures are retried. |
| `cacheEnabled` | `true` | Master switch. `false` forbids caching outright, whatever a call site asks for. |
| `defaultCachePolicy` | `networkOnly` | Policy for `get`/`getAs` calls that don't name one. |
| `isSuccess` | `null` | Reject a `2xx` whose body says otherwise. |
| `httpClientAdapter` | `null` | Certificate pinning, proxies. |
| `observer` | `null` | Request/response/failure hook. |
| `auth` | `null` | Token auth and refresh. |

Settings read at request time — `bypassConnectivityCheck`, `isSuccess` — take effect immediately. Settings baked into the Dio client — `baseUrl`, timeouts, `logging`, `retry`, `auth`, `observer`, `httpClientAdapter` — apply to the client built by `init`, so changing them means calling `init` again.

---

## License

See [LICENSE](LICENSE).
