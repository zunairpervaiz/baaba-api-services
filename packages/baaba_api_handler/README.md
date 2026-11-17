# baaba_api_handler

A typed, functional HTTP client for Flutter. Wraps [Dio](https://pub.dev/packages/dio) with `Either`-based error handling, automatic token refresh, configurable retries, request de-duplication, and a built-in test double.

No exceptions cross the API boundary — every method returns `Either<Failure, T>`.

```dart
final result = await api.getAs<User>(endpoint: '/users/1', parser: User.fromJson);

result.fold(
  (failure) => emit(ErrorState(failure.message)),
  (user)    => emit(LoadedState(user)),
);
```

> **Upgrading from 4.x?** If you switch exhaustively over `ErrorSource` or `ResponseCode`, add a case for the new `certificateRejected`; for most apps that is the whole upgrade. See the 5.0.0 section of [MIGRATION.md](MIGRATION.md).
>
> **Upgrading from 2.0.0?** 3.0.0 and 3.1.0 were never published. Follow the 3.0.0, 4.0.0 and 5.0.0 sections of [MIGRATION.md](MIGRATION.md) in that order. The most common steps: raise `equatable` to 3, replace the removed `configure()`, `setConnectivityCheck()` and `setLogging()` with `ApiServices.init(ApiConfig(...))`, move to Flutter 3.32 (Dart 3.8), drop any response-caching configuration, and add cases for `ErrorSource.gatewayTimeout` and `ErrorSource.certificateRejected` if you switch exhaustively. Coming from 1.x, follow the 2.0.0 section of the same guide first.

## Table of Contents

- [Installation](#installation)
- [Setup](#setup)
  - [More than one client](#more-than-one-client)
- [Making requests](#making-requests)
  - [Endpoints with parameters](#endpoints-with-parameters)
  - [Endpoints and environments from `.env` files](#endpoints-and-environments-from-env-files)
  - [Typed responses](#typed-responses)
  - [Request parameters](#request-parameters)
  - [Response types](#response-types)
  - [HEAD and OPTIONS](#head-and-options)
  - [Uploads](#uploads)
  - [Downloads](#downloads)
  - [Cancellation](#cancellation)
- [Handling failures](#handling-failures)
  - [Validation errors](#validation-errors)
  - [Success that isn't](#success-that-isnt)
  - [Chaining calls](#chaining-calls)
- [Authentication](#authentication)
- [Interceptors](#interceptors)
- [Concurrency](#concurrency)
- [Connectivity checks](#connectivity-checks)
- [De-duplication](#de-duplication)
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
  baaba_api_handler: ^5.0.0
```

Requires Flutter 3.32 / Dart 3.8 or newer. Works on Android, iOS, web, and desktop.

```dart
import 'package:baaba_api_handler/baaba_api_handler.dart';
```

> `Response`, `CancelToken`, `FormData` (Dio) and `Either` (fpdart) are re-exported from this single import — you don't need `dio` or `fpdart` as direct dependencies.

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

`ApiServices.reset()` clears the singleton, config, and loader callbacks, and cancels any requests still in flight on the old client — useful on logout, and in test `tearDown`.

### More than one client

An app that talks to a second backend — a partner's API on another host, with its own CA, a proxy on staging, different timeouts and retries — does not need a hand-built second Dio. Give it a name:

```dart
ApiServices.init(ApiConfig(baseUrl: 'https://api.example.com', auth: ...));

ApiServices.init(
  ApiConfig(
    baseUrl: 'https://partner.example.net/api',
    connectTimeout: const Duration(seconds: 60),
    retry: const RetryPolicy(maxRetries: 1),
  ),
  name: 'partner',
);

final api = ApiServices.instance();              // the default client, as before
final partner = ApiServices.named('partner');    // the second one
```

Each client has its own configuration, auth and token refresh, retry policy, concurrency cap, connectivity cache, de-duplication and cancellation — nothing one client is configured with reaches the other. The default client is unchanged: `init(config)` and `instance()` work exactly as they always have.

| Call | What it does |
| --- | --- |
| `ApiServices.init(config, name: 'partner')` | Builds (or replaces) the client called `partner`. |
| `ApiServices.named('partner')` | Returns it. Throws a `StateError` if `init` was never called for that name — a named client is never built on demand. |
| `ApiServices.configOf('partner')` | Its configuration. `ApiServices.config` is still the default client's. |
| `ApiServices.isInitialized('partner')` | Whether it exists. |
| `ApiServices.reset(name: 'partner')` | Discards that client alone and cancels its in-flight requests. `reset()` with no name discards every client. |

**Loading indicator.** `configureLoader(...)` without a name is shared by every client, and requests on all of them count toward one `onShow`/`onHide` pair — a request on each of two clients opens your dialog once and closes it once. To give a client an indicator of its own, with its own count, pass its name: `configureLoader(name: 'partner', onShow: ..., onHide: ...)`.

**Tests.** `FakeApiServices(client: 'partner')` applies the `partner` client's `isSuccess`, `mapFailure` and observer, just as the real client would.

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

`get`, `post`, `put`, `patch`, `delete`, `upload`, and `download` are available. With `baseUrl` set, endpoints are relative; an absolute endpoint is used as-is, so hitting a CDN or third-party host from the same client works fine. The join never doubles or drops a slash: `https://api.example.com/v1/` + `/users`, `https://api.example.com/v1` + `users` and every other combination all reach `https://api.example.com/v1/users`.

### Endpoints with parameters

`ApiEndpoint` turns a path template with `{}` placeholders into an endpoint, filling them in order:

```dart
const orderAttachment = ApiEndpoint('orders/{}/attachments/{}');

await api.get(endpoint: orderAttachment.fill([orderId, fileName]));
// GET <baseUrl>/orders/42/attachments/scan%201.pdf
```

Each argument is URL-encoded as **one path segment**, so a `/`, `?`, `#` or space inside an id stays part of that id instead of reshaping the URL. `fill` throws an `ArgumentError` when the argument count does not match the placeholders, or when an argument is empty, `.` or `..` — none of which survive as a segment.

`ApiEndpoint` is an extension type over `String`: it costs nothing at runtime and is accepted anywhere an endpoint is, so adopting it changes no call site. An absolute template (`https://cdn.example.com/files/{}`) bypasses `baseUrl` like any absolute endpoint.

### Endpoints and environments from `.env` files

Apps usually keep their hosts and paths out of the code, in `.env` files, and want them hidden in the compiled app. The companion dev dependency [`baaba_api_generator`](https://pub.dev/packages/baaba_api_generator) generates typed, obfuscated accessors from those files — no hand-written wrapper per endpoint, and no `envied`.

**1. Dependencies**

```yaml
dependencies:
  baaba_api_handler: ^5.0.0

dev_dependencies:
  build_runner: ^2.4.0
  baaba_api_generator: ^1.0.0
```

**2. `build.yaml` — required.** build_runner only reads files listed in your app's `build.yaml` sources, and the defaults do not include `env/`. Skip this and the build fails with "cannot read env/endpoints.env" (with `envied`, the same omission surfaced as "Environment variable not found"). Listing `sources` replaces the defaults, so keep `lib/**`:

```yaml
# build.yaml, next to pubspec.yaml
targets:
  $default:
    sources:
      - $package$
      - lib/**
      - env/**
      - test/**
      - pubspec.yaml
```

**3. The `.env` file**

```properties
# env/endpoints.env
LOGIN=auth/login
UPDATE_ORDER=orders/{orderId}
UPDATE_ORDER_ATTACHMENT=orders/{orderId}/attachments/{attachmentId}
LEGACY_STATEMENT=statements/{}/period/{}    # envied-style {} works too
```

**4. The annotated declaration**

```dart
import 'package:baaba_api_handler/baaba_api_handler.dart';

part 'endpoints.g.dart';

@BaabaApiEndpoint(path: 'env/endpoints.env')
typedef Endpoints = _Endpoints;
```

**5. Build and use**

```sh
dart run build_runner build
```

```dart
await api.get(endpoint: Endpoints.updateOrder(id));        // orders/42
await api.get(endpoint: Endpoints.login);                  // auth/login
Endpoints.updateOrderAttachment(id, fileName);                 // each argument one encoded segment
Endpoints.legacyStatement(account, period);                    // {} → arg1, arg2
```

A key with `{name}` placeholders becomes a method with those parameters; `{}` placeholders become `arg1`, `arg2`, …; a key without any becomes a getter. Every member returns an `ApiEndpoint`, so the slash and encoding rules above apply.

`@BaabaApiEnvironment` does the same for configuration, typed as `String`, `int`, `bool` or `Uri` and checked at build time:

```dart
@BaabaApiEnvironment(path: 'env/stage.env')
abstract final class StageEnv {
  static final Uri baseUrl = _StageEnv.baseUrl;                  // BASE_URL
  static final int connectTimeoutSeconds = _StageEnv.connectTimeoutSeconds;
  @BaabaApiField(name: 'HUB')
  static final String? hubUrl = _StageEnv.hubUrl;                // empty → null
}
```

Values are **obfuscated by default**: each is stored as a fresh random key and the XORed value, as constant integer lists, decoded on first use. A duplicate or missing key, a malformed placeholder, or a value that does not parse fails the build with the file and line. Moving over from `envied` is a change of annotation — your `.env` files work as they are. The [generator's README](https://pub.dev/packages/baaba_api_generator) has the details.

> **This is obfuscation, not encryption.** It defeats a strings search of your APK or IPA — nothing more. Anyone with your source code or a debugger can read every value, because the key to decode them ships in the same binary. **Real secrets — API keys or credentials that grant access to anything — must never ship in an app**, obfuscated or not.

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
| `retryable` | `bool?` | `true`: may be retried even if it isn't a `GET`. `false`: never retried. See [Retrying one call](#retrying-one-call). |
| `extra` | `Map<String, dynamic>?` | Copied into `RequestOptions.extra`, for `retryIf`, interceptors and the observer. |

`get`, `getAs`, `head` and `options` additionally accept `dedupe` — see [De-duplication](#de-duplication).

### Response types

Bodies are decoded as JSON by default. Pass `responseType` for anything else — an image you want in memory, or an endpoint that returns plain text:

```dart
// Raw bytes, without writing to disk the way download() does.
final logo = await api.get(
  endpoint: '/assets/logo.png',
  responseType: ResponseType.bytes,
);

// Text that isn't JSON.
final csv = await api.get(
  endpoint: '/reports/export.csv',
  responseType: ResponseType.plain,
);
```

It works on every method, including the `*As<T>` variants, where the parser then receives whatever the response type produced rather than decoded JSON.

For a file you want on disk rather than in memory, use [`download`](#downloads) — it streams and never holds the whole body.

---

### HEAD and OPTIONS

`head` asks for headers without a body — useful to check that a resource exists, or to read its `Content-Length` before committing to a download:

```dart
final result = await api.head(endpoint: '/files/report.pdf');

final size = result.fold(
  (_) => null,
  (response) => response.headers.value('content-length'),
);
```

`options` asks the server which methods apply to a resource. Both are idempotent, so transient failures are retried just like a `get`.

---

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

Downloads, and requests with `responseType: ResponseType.bytes` or `stream`, send `Accept: */*` unless you pass your own `headers` — a JSON `Accept` gets a `406` from servers that honour it, static file handlers in particular.

### Cancellation

`cancelRequest()` cancels every in-flight request:

```dart
@override
void onClose() {
  api.cancelRequest(cancellationReason: 'Screen closed');
  super.onClose();
}
```

That is all-or-nothing, so a screen tearing down would abort requests belonging to screens still on the stack. Tag the requests you want to cancel together:

```dart
await api.get(endpoint: '/feed', tag: 'feed');
await api.get(endpoint: '/stories', tag: 'feed');

// Cancels only those two.
api.cancelRequest(tag: 'feed', cancellationReason: 'Left the feed');
```

Untagged requests are cancelled only by a call that omits `tag`. A tagged request opts out of [de-duplication](#de-duplication), for the same reason a caller-supplied `CancelToken` does: cancelling one tag must not abort a collapsed request another caller is still waiting on.

For a single request, pass your own `CancelToken`.

---

## Handling failures

`Failure` carries a user-facing `message`, a mapped `code`, and the raw response:

| Field | Description |
| --- | --- |
| `message` | Human-readable. Extracted from the body's `message`, `detail`, `error` or `msg` key, then the field messages under `errors`, then `title` (ASP.NET's problem details), falling back to a generic string for the status. |
| `errorType` | `ErrorSource` — semantic enum (`notFound`, `unauthorized`, `parseError`, …). |
| `code` | `ResponseCode` — enum with an integer `value`. Collapses unrecognised statuses to `defaultError`. |
| `statusCode` | The literal HTTP status, e.g. `418`. `null` for failures that never reached the server. |
| `data` | The raw response body. `null` for offline, timeout, and cancellation. |
| `validationErrors` | Per-field errors parsed from an `errors` object. `null` when absent. |
| `errorCode` | The server's own code — `code` or `errorCode`, top level or inside `error`. `null` when absent. |
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

By itself that produces a generic `badRequest` failure, which throws away any error code the body carried. Add `onRejected` to build the `Failure` yourself:

```dart
ApiServices.init(ApiConfig(
  isSuccess: (r) => r.data is! Map || r.data['success'] != false,
  onRejected: (r) => Failure(
    ErrorSource.forbidden,
    ResponseCode.forbidden,
    r.data['message'] as String? ?? 'Request failed',
    data: r.data,
    statusCode: r.statusCode,
  ),
));
```

Return `null` to fall back to the generic failure. It is only consulted when `isSuccess` returns `false` — or throws, which counts as a rejection rather than escaping as an exception.

`isSuccess` is not applied to `head()` or `download()` — neither has a body in `response.data` to judge.

### Mapping failures for your app

`mapFailure` sees every `Failure` before the caller does — HTTP errors, timeouts, offline, cancellation, parse errors, and rejected bodies — so app-specific wording and codes live in one place instead of every repository:

```dart
ApiServices.init(ApiConfig(
  mapFailure: (failure) {
    // A 401 from login is a wrong password, not an expired session.
    if (failure.statusCode == 401 &&
        failure.requestOptions?.path == '/auth/login') {
      return Failure(
        ErrorSource.unauthorized,
        ResponseCode.unauthorized,
        'Wrong username or password.',
        data: failure.data,
        statusCode: 401,
      );
    }
    if (failure.errorCode == 'ACCOUNT_LOCKED') {
      return Failure(
        failure.errorType,
        failure.code,
        'Your account is locked. Contact HR.',
        data: failure.data,
        statusCode: failure.statusCode,
      );
    }
    return null; // keep it as it is
  },
));
```

A returned failure without `requestOptions` gets the original's. The observer reports the mapped failure, and `FakeApiServices` applies the mapper too. A mapper that throws leaves the failure unchanged.

### Chaining calls

One call is easy to `fold`. A flow of several, each needing the last one's result, nests a `fold` per step. Write it straight through instead: `orThrow()` unwraps a result or throws, and `guardApi` turns the flow back into an `Either` at its edge.

```dart
Future<Either<Failure, Receipt>> checkout(Cart cart) => guardApi(() async {
  final order = await api
      .postAs(endpoint: '/orders', parser: Order.fromJson, data: cart.toJson())
      .orThrow();
  final payment = await api
      .postAs(endpoint: '/orders/${order.id}/pay', parser: Payment.fromJson)
      .orThrow();
  return api
      .getAs(endpoint: '/receipts/${payment.receiptId}', parser: Receipt.fromJson)
      .orThrow();
});
```

The first failure stops the flow, and the caller gets it exactly as the client returned it — status, body, message and all.

| | |
| --- | --- |
| `future.orThrow()` | On a `Future<Either<Failure, T>>` — any request, typed or not. Returns `T`, or throws `ApiException`. Also on an `Either` you already awaited. |
| `ApiException` | Wraps the `Failure`: `failure`, plus `statusCode`, `data`, `message` and `errorType` from it. |
| `guardApi(() async { ... })` | Returns `Future<Either<Failure, T>>` and never throws. An `ApiException` becomes its `Failure`; a thrown `Failure` is returned as is; a `DioException` (Dio used directly in the flow) becomes the `Failure` the client would build, `mapFailure` included (the default client's, or pass `client: 'name'`); anything else is `ErrorSource.defaultError`. |

Anything that lands in that last case is a bug rather than a network problem, and the generic `Failure` hides it — pass `onUnexpected` to report it:

```dart
guardApi(() async { ... }, onUnexpected: (e, st) => Sentry.captureException(e, stackTrace: st));
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

A burst of concurrent `401`s — the usual shape of a token expiring — all wait on one refresh and retry, rather than only the first succeeding. `refreshTimeout` bounds that wait. A refresh request made through the same client that itself `401`s — an expired refresh token — fails at once, so `onRefreshFailed` fires without delay. A `401` that arrives after another request's refresh has already finished is replayed with the new token rather than triggering a second refresh.

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

### Login, logout and other requests that must not refresh

A `401` from the login endpoint means a wrong password. Without help, it starts a refresh with nothing to refresh, which fails and fires `onRefreshFailed` — logging the user "out" of the login screen. Name those requests in `skipRefresh`:

```dart
auth: AuthConfig(
  getToken: getToken,
  onTokenRefresh: refresh,
  skipRefresh: (options) => const {
    '/auth/login',
    '/auth/refresh',
    '/auth/logout',
  }.contains(options.path),
),
```

Their `401` surfaces as an ordinary `Failure`. They still carry the token when there is one, since logout usually needs it.

### Keeping the session when a refresh can't be tried

`onTokenRefresh` returns a `bool`, so a refresh that failed because the device was offline ends the session just as a refused refresh token does. Use `refreshSession` instead to tell the two apart:

```dart
auth: AuthConfig(
  getToken: getToken,
  refreshSession: () async {
    try {
      await authRepository.refresh();
      return RefreshOutcome.refreshed;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      return status == 400 || status == 401 || status == 403
          ? RefreshOutcome.sessionExpired   // fires onRefreshFailed
          : RefreshOutcome.failed;          // keeps the session
    }
  },
  onRefreshFailed: () => authController.logout(),
),
```

| Outcome | Waiting requests | `onRefreshFailed` |
| --- | --- | --- |
| `refreshed` | Replayed with the new token. | — |
| `sessionExpired` | Fail with their `401`. | Fires. |
| `failed` | Fail with their `401`; a later request tries again. | Does not fire. |

Supply exactly one of `onTokenRefresh` and `refreshSession`. A throw from `refreshSession` counts as `failed`; a throw from `onTokenRefresh` still ends the session, as before.

### Refreshing before the token expires

With `isTokenExpired`, a request whose token has run out refreshes *before* it is sent, instead of spending a round trip on a `401`:

```dart
auth: AuthConfig(
  getToken: getToken,
  refreshSession: refresh,
  isTokenExpired: () async {
    final expiresAt = await storage.readExpiry();
    return expiresAt != null &&
        DateTime.now().add(const Duration(seconds: 30)).isAfter(expiresAt);
  },
),
```

Concurrent requests share the one refresh. If it ends the session, the request is not sent and fails as a `401` (`ErrorSource.unauthorized`); if it merely fails, the request goes out with the token it has, and a `401` for it does not try the refresh again. Not asked for `skipRefresh` requests, or for requests made by the refresh itself. A throwing check counts as "not expired".

#### JWTs

If the token is a JWT, its own `exp` claim says when it expires — no need to store the expiry separately:

```dart
auth: AuthConfig(
  getToken: storage.readAccessToken,
  isTokenExpired: jwtExpiryCheck(storage.readAccessToken),
  refreshSession: refresh,
),
```

`jwtExpiryCheck(getToken, {skew})` reads the token and calls `jwtExpired(token, {skew})`, which you can also use directly. It decodes the payload as base64url (restoring missing padding), reads `exp`, and reports `true` once the current time plus `skew` (default 30 seconds) reaches it — so a token about to die is refreshed before it travels.

- A **malformed** token — not three parts, a payload that is not base64url JSON, a non-numeric `exp` — counts as expired: refreshing is the safe answer to a token you cannot read.
- A token with **no `exp`** never expires (RFC 7519), so it is not refreshed on every request.
- No token at all (`null` or empty) is not expired: there is no session to refresh.
- **The signature is not verified.** This only decides *when to refresh*; never use it to decide whether to trust a token.

### Which hosts get the token

By default, only the host in your `baseUrl`.

That matters because `baseUrl` supports absolute endpoints, so one client can reach a CDN, an S3 presigned URL, or a third-party API. Sending the token to all of them leaks your session to whoever the caller names — and it *breaks* presigned URLs outright, since S3 rejects a request carrying both a presigned signature and an `Authorization` header.

To span several hosts you own:

```dart
auth: AuthConfig(
  getToken: getToken,
  onTokenRefresh: refresh,
  sendTokenTo: (uri) => uri.host.endsWith('.mycompany.com'),
),
```

The check is by host, so a different port or scheme on the same host still receives the token — use the predicate if that matters to you. A predicate that throws is treated as "don't send". When `baseUrl` isn't set there's nothing to compare against and the token goes everywhere.

A `401` from a host the token was never sent to won't trigger a refresh, which also means a third party's `401` can't cascade into `onRefreshFailed` and sign your user out.

---

## Interceptors

`ApiObserver` can watch a request but not change it. For anything that needs to *modify* one — a correlation id, a tenant header computed at call time, request signing, a router that serves fixtures during local development — pass your own Dio interceptors:

```dart
ApiServices.init(ApiConfig(
  interceptors: [
    InterceptorsWrapper(onRequest: (options, handler) {
      options.headers['X-Correlation-Id'] = const Uuid().v4();
      handler.next(options);
    }),
  ],
));
```

They sit **after auth and before retry**. After auth, so a signing interceptor sees the `Authorization` header it has to cover. Before retry and the logger, so a replayed request passes through them again — a signature carrying a timestamp is regenerated per attempt rather than replayed stale — and so what you add is what gets logged.

They run in the order given, and are applied when the client is built, so changing them means calling `init` again.

> A retry replays the **same** `RequestOptions` instance rather than a copy. Read a header off it after the fact and you see the last attempt's value, not the one that attempt sent.

---

## Concurrency

A screen that fires twenty requests on mount sends all twenty at once. On a mobile connection that saturates the connection pool — every request reports a worse latency than it would have alone — and it is a reliable way to trip server-side rate limiting that your retry policy then has to clean up.

```dart
ApiServices.init(const ApiConfig(maxConcurrentRequests: 6));
```

Requests past the cap queue in the order they were made and start as slots free up. The cap governs actual network calls: a request collapsed by [de-duplication](#de-duplication) doesn't consume a slot of its own. A queued request is still cancellable, and still holds the loading indicator — it's pending, not finished.

Unset by default, which is unlimited.

---

## Connectivity checks

Every request runs a pre-flight connectivity probe, so an offline call fails fast with `ErrorSource.noInternetConnection` instead of waiting out a timeout. A positive result is reused for `connectivityCacheTtl` (5s by default); a negative one is never cached, since that is exactly when the user is hammering retry.

The default probe reaches third-party hosts. That is wrong often enough to matter — corporate networks block it, privacy reviews object to it, and it says nothing about whether *your* API is up. Point it at your own health endpoint:

```dart
ApiServices.init(ApiConfig(
  connectivityProbe: () async {
    try {
      final res = await Dio().head('https://api.example.com/health');
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  },
));
```

It must not throw — one that does is read as "offline". To skip the check entirely, use `bypassConnectivityCheck: true`.

---

## De-duplication

Two identical `GET`s (or `HEAD`/`OPTIONS` requests) in flight at the same time share one network call — the common case being several widgets on one screen asking for the same resource. Pass `dedupe: false` to opt out. "Identical" means the same url, query, body, headers and `responseType` — a request for bytes is never handed another caller's decoded JSON. It is skipped automatically when you supply your own `CancelToken` or a `tag`, since cancelling one caller must not cancel the other, and when you pass a progress callback, which only one caller's request could drive.

De-duplication only collapses overlapping calls: sequential requests each hit the network. The package does not cache responses — if you need offline data, store it in your own persistence layer.

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

### Retrying one call

`retryIf` only sees the method and the path, so it cannot know that a particular `POST` only reads — a GraphQL query, a search with a body. Say so where you make the call:

```dart
await partner.post(
  endpoint: '/graphql',
  data: getBalanceQuery,
  retryable: true,                     // safe: a query has no side effect
  extra: {'operation': 'GetBalance'},  // for retryIf, interceptors, the observer
);

await partner.post(endpoint: '/graphql', data: transferMutation); // not retried

await api.get(endpoint: '/poll', retryable: false); // never retried, not even on 429/503
```

- `retryable: true` stands in for idempotency on this call: transport errors and every status in `retryableStatusCodes` are retried. `maxRetries`, backoff and `retryIf` still apply.
- `retryable: false` never retries — not even a `429` or `503`.
- `null`, the default, leaves it to the method as described above.

Every method takes both, including the `*As<T>` variants, `head`, `options`, `upload` and `download`. `extra` lands in `RequestOptions.extra` (a copy — your map is never modified), and the flag is there too under `RetryPolicy.retryableKey`, so `retryIf` can tell:

```dart
retryIf: (err, attempt) =>
    err.requestOptions.extra['operation'] != 'Transfer',
```

Two otherwise identical `GET`s with different `extra` or `retryable` are not [de-duplicated](#de-duplication) together. `FakeApiServices` records both on each `RecordedCall`.

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

Observers receive **masked copies**: tokens, cookies, passwords and the like are redacted per [`ApiLogOptions.redact`](#redaction), on by default. The response and failure your own code receives are the real ones.

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

### Pinning by CA

`ApiConfig.pinning` trusts each host only if its certificate chains to the roots you list for it:

```dart
ApiServices.init(ApiConfig(
  baseUrl: 'https://api.example.com',
  pinning: PinningConfig(
    rootsPemByHost: {
      'api.example.com': [Certs.internalRootCa],
      // Any subdomain, at any depth — not the bare domain itself.
      '*.partner.example.net': [Certs.partnerRootCa, Certs.partnerNextCa],
    },
    unlistedHosts: UnlistedHostPolicy.system, // the default
  ),
));
```

- **The handshake fails, no callback involved.** Each set of roots gets its own `HttpClient` built on `SecurityContext(withTrustedRoots: false)` with only those roots added. There is no `badCertificateCallback` at all, so no code path can wave a certificate through: one that doesn't chain to the listed roots fails the TLS handshake and the request never leaves the device.
- **A distinct failure.** A rejected certificate surfaces as `ErrorSource.certificateRejected` (`ResponseCode.certificateRejected`, `-10`) — not `noInternetConnection` or `connectionFailure` — so you can tell an interception attempt or a misconfigured proxy from a dropped connection, and report it. It is never retried. (An unpinned client on mobile or desktop reports a certificate the platform refuses the same way.)
- **Hosts you didn't list** use the platform's trust store by default, so pinning your API doesn't break the CDN or crash reporter sharing the client. Set `unlistedHosts: UnlistedHostPolicy.refuse` to fail them instead (also as `certificateRejected`, without connecting).
- **Matching.** A key matches exactly, or `*.example.com` matches any subdomain. An exact key beats a wildcard, and a longer wildcard beats a shorter one. Case is ignored.
- **Pin roots or intermediates, not leaf certificates**, so a routine renewal doesn't lock out every installed copy of the app. Add the next CA next to the current one before rotating.
- **A PEM that doesn't parse fails closed**: requests to that host fail with `certificateRejected`.
- **Web: not supported.** The browser does its own TLS and offers no way to restrict it, so on web `pinning` is ignored and requests use the browser's normal validation. The package selects the transport with a conditional import, so the core library still compiles for web.

`pinning` (and `proxy`, below) and `httpClientAdapter` are mutually exclusive — they all decide the transport, and setting both trips an assert.

### Proxy for selected hosts

`ApiConfig.proxy` sends requests for the hosts you list through an HTTP proxy, and everything else direct:

```dart
ApiServices.init(
  ApiConfig(
    baseUrl: 'https://partner.example.net/api',
    pinning: PinningConfig(rootsPemByHost: {
      'partner.example.net': [Certs.partnerRootCa],
    }),
    proxy: ProxyConfig(
      proxy: isStaging ? 'proxy.staging.example.com:3128' : null, // host:port
      hosts: {'partner.example.net'},
    ),
  ),
  name: 'partner',
);
```

It is applied through `HttpClient.findProxy`, per host: listed hosts get `PROXY host:port`, everything else `DIRECT`. `hosts` matches like `pinning` does — exactly, or `*.example.com` for any subdomain. A `null` or empty `proxy` sends everything direct, so you can pass an environment's value straight through.

**It works with pinning.** `https` requests are tunnelled with `CONNECT`, and TLS runs end to end inside the tunnel, still verified against the pinned roots — so the proxy never sees plaintext, and a proxy that tries to terminate TLS itself is rejected with `certificateRejected`. `pinnedHttpClient` and `pinnedIoClient` take the same `proxy:` argument.

Ignored on web, where the browser decides how to reach the network. Mutually exclusive with `httpClientAdapter`.

### Pinned clients outside Dio

A WebSocket, a SignalR hub or any library that brings its own HTTP client can use the same roots through `package:baaba_api_handler/io.dart`:

```dart
import 'package:baaba_api_handler/io.dart';

final roots = pinning.rootsFor('hub.example.com')!;

// dart:io HttpClient — e.g. web_socket_channel
final channel = IOWebSocketChannel.connect(
  Uri.parse('wss://hub.example.com/ws'),
  customClient: pinnedHttpClient(roots),
);

// package:http IOClient — e.g. SignalR's negotiate and long-polling requests
final hub = HubConnectionBuilder()
    .withUrl(
      'https://hub.example.com/hub',
      options: HttpConnectionOptions(client: pinnedIoClient(roots)),
    )
    .build();
```

Both trust the given roots and nothing else, and throw a `TlsException` at construction if a PEM doesn't parse. `io.dart` imports `dart:io`, so it is for mobile and desktop only — import it from code that never compiles for web. The core import stays web-safe.

### Your own adapter

For anything `pinning` doesn't cover, `httpClientAdapter` replaces the transport entirely. It is also the hook for routing traffic through Charles or Proxyman while debugging:

```dart
import 'dart:io';
import 'package:dio/io.dart';

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
| `requestHeader` | `false` | Log request headers (secrets masked — see [Redaction](#redaction)). |
| `requestBody` | `true` | Log the request body. |
| `responseHeader` | `false` | Log response headers. |
| `responseBody` | `true` | Log the response body. |
| `error` | `true` | Log errors. |
| `maxWidth` | `90` | Wrap width. |
| `compact` | `true` | Compact JSON output. |
| `trimBase64` | `false` | Collapse base64 blobs — see below. |
| `redact` | `true` | Mask secrets in the log and in what the observer receives — see below. |
| `redactHeaders` | `authorization`, `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key` | Headers to mask (`Authorization` always is). |
| `redactQueryParams` | `t`, `token`, `access_token`, `refresh_token`, `id_token`, `api_key`, `apikey` | Query parameters to mask. |
| `redactBodyFields` | `password`, `token`, `accessToken`, `refreshToken`, `access_token`, `refresh_token`, `idToken`, `id_token` | JSON body fields to mask, at any depth. |
| `redactKeepChars` | `4` | Leading characters left visible. |
| `logPrint` | `debugPrint` | Where lines go. |

Release builds never attach a logger, whatever this says.

### Redaction

Secrets are masked by default, so you can turn `requestHeader`/`responseHeader` on while debugging without pasting a live token into a bug report:

```
╟ authorization: Bearer eyJh…[redacted]
╟ set-cookie: [sess…[redacted]]
║ {username: ada, password: …[redacted]}
║    "accessToken": "eyJh…[redacted]",
```

- **Headers:** `Authorization` always, plus everything in `redactHeaders`. An auth scheme (`Bearer`, `Basic`, …) stays readable.
- **Query parameters** in `redactQueryParams`, whether passed as `params` or written into the endpoint — realtime hubs pass the token as `/hub?t=...`, which is why `t` is on the list.
- **JSON body fields** in `redactBodyFields`, at any depth, in request *and* response bodies — the login response is where the tokens are. Map bodies, JSON strings, form-urlencoded strings (`grant_type=password&password=...`) and `FormData` fields are covered; other bodies (bytes, XML) pass through.
- A masked header, query parameter or token field (a body field whose name contains `token`) keeps its first `redactKeepChars` characters, enough to tell two tokens apart; values no longer than twice that are masked entirely. Any other body field — `password`, an OTP, an ID number — is always masked entirely, since its first characters are part of the secret.
- Redirect locations are masked too, so `response.realUri` handed to the observer carries no token.
- Names match case-insensitively.

**It applies to the observer too** — `onRequest`, `onResponse` and `onFailure` receive masked copies, so a crash reporter never receives a token either. It stays on under `ApiLogOptions.disabled()` for that reason.

Only those copies are masked. What goes over the wire and what your code receives in `Right`/`Left` is never touched.

Extend the sets rather than replace them, so the defaults keep working:

```dart
logging: ApiLogOptions(
  redactBodyFields: {...ApiLogOptions.defaultRedactBodyFields, 'nationalId', 'otp'},
  redactHeaders: {...ApiLogOptions.defaultRedactHeaders, 'x-session-id'},
),
```

`redact: false` turns it off for both the log and the observer.

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
| `stubJson(method, endpoint, body)` | Queue a response. A non-`2xx` `statusCode` becomes a failure, as it does in production. |
| `stubFailure(method, endpoint, ...)` | Queue a failure, from a `Failure` or a status/body — built exactly as the real client builds one, so a `401` is `ErrorSource.unauthorized` carrying the body's message. |
| `stubOffline(method, endpoint)` | Queue the no-connection short-circuit. |
| `stub(method, endpoint, either)` | Queue a raw `Either` for full control. |
| `stubDownload(endpoint)` | Queue a successful `download`. The `savePath` is recorded as the call's `data`. |
| `recordedCalls` | Every call made, with endpoint, body, params, headers, files. |
| `cancellations` / `cancelledTags` | Reasons and tags passed to `cancelRequest`. |
| `reset()` | Clear stubs and history. |

Stub the same endpoint more than once to script a sequence — each call consumes one entry and the last repeats, which makes "fails, then succeeds on retry" easy to set up. Calling an endpoint you didn't stub throws a `StateError` naming it, so an unexpected call fails loudly instead of quietly returning null.

The fake honours the parts of `ApiConfig` that shape an outcome, the same way the real client does: `isSuccess` (except on `head` and `download`), an already-cancelled `CancelToken`, and the `observer` — `onRequest` for every call that would have reached the network, then exactly one of `onResponse` or `onFailure` (both, for a `*As<T>` parse failure). Test your observer wiring through it with `ApiServices.init(ApiConfig(observer: ...))`.

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
| `connectivityProbe` | `null` | Replaces the default third-party ping with your own check. |
| `logging` | `ApiLogOptions()` | Console logger settings. |
| `retry` | `RetryPolicy()` | How transient failures are retried. |
| `isSuccess` | `null` | Reject a `2xx` whose body says otherwise. |
| `onRejected` | `null` | Builds the `Failure` for a response `isSuccess` rejected. |
| `mapFailure` | `null` | Rewrites any `Failure` before the caller sees it. |
| `httpClientAdapter` | `null` | Replaces the transport. Mutually exclusive with `pinning`. |
| `pinning` | `null` | Certificate pinning by CA, per host. Ignored on web. |
| `proxy` | `null` | Send selected hosts through an HTTP proxy, the rest direct. Ignored on web. |
| `observer` | `null` | Request/response/failure hook. |
| `interceptors` | `[]` | Your own Dio interceptors, inserted after auth and before retry. |
| `maxConcurrentRequests` | `null` | Cap on requests in flight at once. Unlimited when unset; must be positive. A token refresh made through the client is never queued behind it. |
| `auth` | `null` | Token auth and refresh. |

Settings read at request time take effect immediately: `bypassConnectivityCheck`, `isSuccess`, `onRejected`, `mapFailure`, and the observer's `onResponse`/`onFailure`. The rest are fixed when `init` builds the client, so changing them means calling `init` again: `baseUrl`, timeouts, `defaultHeaders`, `logging`, `retry`, `auth`, `interceptors`, `httpClientAdapter`, `pinning`, `proxy`, `connectivityProbe`, `connectivityCacheTtl`, `maxConcurrentRequests`, and the observer's `onRequest`.

---

## License

See [LICENSE](LICENSE).
