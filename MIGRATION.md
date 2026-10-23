# Migrating to 4.0.0

> **Coming from 2.0.0 on pub.dev?** 3.0.0 was never published, so its changes arrive with 4.0.0 too. Do [Migrating to 3.0.0](#migrating-to-300) first, then this section.

4.0.0 requires Dart 3.8 / Flutter 3.32, and removes response caching along with the `api_cache_manager` dependency (and transitively `sqflite`). Every request now goes to the network. Apps already on Flutter 3.32+ that never passed a `cachePolicy` only need to delete any leftover cache configuration and, if they switch exhaustively over `ErrorSource` or `ResponseCode`, add a case for the new `gatewayTimeout`. 4.0.0 also stops applying `isSuccess` to `head()`.

Reading `AuthConfig.onTokenRefresh` — rare outside tests — now needs a null check: the field is nullable, since `refreshSession` is the alternative to it. Passing it is unchanged.

## 0. Flutter 3.32 / Dart 3.8 or newer

If `flutter pub get` reports that `baaba_api_handler` 4.x requires a newer SDK, upgrade Flutter (`flutter upgrade`) or stay on 3.x until you can.

## 1. Remove cache arguments and configuration

These no longer exist, and each is a compile error:

| Removed | Fix |
|---|---|
| `cachePolicy:` / `cacheMaxAge:` on `get`/`getAs` | Delete the argument. |
| `ApiConfig(cacheEnabled:, defaultCachePolicy:, cacheMaxEntries:, cacheMaxBytes:)` | Delete the field, and the same names on `copyWith`. |
| `CachePolicy` | Delete every use, along with the arguments above. |
| `response.isFromCache` (the `CachedResponse` extension) | Every response is from the network now; delete the branch. |
| `ApiCacheHelper` | Store the data yourself — `shared_preferences`, Hive, `sqflite` directly, or `api_cache_manager` added as your own dependency. |
| `APICacheDBModel` re-export | Import it from `api_cache_manager` directly if you still use it. |

```dart
// Before
final result = await api.get(
  endpoint: '/products',
  cachePolicy: CachePolicy.networkFirst,
);

// After
final result = await api.get(endpoint: '/products');
```

If you relied on `networkFirst` for offline tolerance, keep the last good response in your repository layer and fall back to it on `Left`.

## 2. Exhaustive switches over `ErrorSource` or `ResponseCode`

`ErrorSource.cacheError` and `ResponseCode.cacheError` are gone, so a `case` naming them no longer compiles — delete it. The integer `-5` is retired rather than reused; `mapStatusCodeToEnum(-5)` now returns `ResponseCode.defaultError`, and every other code keeps its value.

`ErrorSource.gatewayTimeout` and `ResponseCode.gatewayTimeout` (`504`) are new, so an exhaustive switch needs a case for them. A `504` used to arrive as `defaultError` with "An unexpected error occurred"; code that recognised a gateway timeout by checking `failure.statusCode == 504` keeps working, but can now match the error type instead.

## 3. `isSuccess` no longer runs on `head()`

A `HEAD` response has no body, so a body-reading predicate — `r.data['success'] == true` — threw on every `head()` call, and a throw counts as a rejection. `head()` now skips `isSuccess`, as `download()` always has. If you relied on `isSuccess` to reject a `HEAD` based on its headers, check them at the call site instead.

## 4. Logout

`ApiCacheHelper.instance.clearAllCache()` on logout is no longer needed — the package persists nothing. Keep calling `ApiServices.reset()`.

## 5. Leftover database

Apps upgrading from 3.x keep the SQLite file `api_cache_manager` created. It is harmless but no longer read; delete it if disk space matters, or call `APICacheManager().emptyCache()` once before dropping the dependency.

---

# Migrating to 3.0.0

Most apps only need to raise their `equatable` constraint. The other changes affect specific code patterns, and each is a compile error with a mechanical fix.

## 1. Raise `equatable` to 3

`Failure` extends `Equatable`, so your app and this package must use the same major version. If your pubspec pins version 2, `flutter pub get` will fail to resolve:

```yaml
dependencies:
  equatable: ^3.0.0
```

## 2. Replace the removed configuration methods

`configure()`, `setConnectivityCheck()` and `setLogging()` are gone. Each one maps to a field on `ApiConfig`:

| Removed | Replacement |
| --- | --- |
| `ApiServices.configure(getToken:, onTokenRefresh:, ...)` | `ApiServices.init(ApiConfig(auth: AuthConfig(...)))` |
| `ApiServices.setConnectivityCheck(enabled: false)` | `ApiServices.init(ApiConfig(bypassConnectivityCheck: true))` |
| `ApiServices.setLogging(options)` | `ApiServices.init(ApiConfig(logging: options))` |

Merge them into one `init()` call; a before-and-after example is under "Recommended: move to `ApiConfig`" below. `configureLoader` is unchanged.

## 3. Exhaustive switches over `HttpMethod`

`HttpMethod` gained `head` and `options`. Add both cases or a wildcard.

## 4. Classes that implement `ApiServices`

The interface gained `head()` and `options()`. If you implemented it by hand for tests, add them, or use `FakeApiServices` from `package:baaba_api_handler/testing.dart`, which is kept up to date.

---

# Migrating to 2.0.0

Short version: **your existing code keeps compiling and behaving the same**, with three exceptions listed below. Everything replaced in 2.0.0 is deprecated rather than removed, and will be dropped in 3.0.0.

---

## The three things that can actually break you

### 1. Exhaustive switches over `ErrorSource` or `ResponseCode`

Both enums gained a `parseError` variant, for a response that arrived fine but could not be deserialized. If you switch exhaustively over either, that switch no longer compiles:

```dart
// Before — compiles in 1.x, fails in 2.0.0
String label(ErrorSource source) => switch (source) {
      ErrorSource.notFound => 'Not found',
      // ...every other case...
    };
```

Add the case, or a wildcard:

```dart
String label(ErrorSource source) => switch (source) {
      ErrorSource.notFound => 'Not found',
      ErrorSource.parseError => 'Unexpected response',
      _ => 'Something went wrong',
    };
```

This is the only source-breaking change, and the reason 2.0.0 is a major release.

### 2. Requests now time out after 30 seconds

1.x set no timeout at any layer. A request to a host that accepted the connection and then went silent hung indefinitely. 2.0.0 defaults to 30s each for connect, receive, and send.

If you have an endpoint that legitimately takes longer — a report build, a large export — raise the bound rather than removing it:

```dart
// Per request, which is usually what you want
await api.get(endpoint: '/reports/annual', receiveTimeout: const Duration(minutes: 5));

// Or globally
ApiServices.init(const ApiConfig(receiveTimeout: Duration(minutes: 2)));
```

### 3. `Failure` equality includes the response body

`Failure.props` now includes `data` and `statusCode`. Two failures that differ only in body are no longer equal. This matters if you assert on `Failure` equality in tests, or use them as map keys.

---

## Recommended: move to `ApiConfig`

`configure()`, `setConnectivityCheck()`, and `setLogging()` still work in 2.x (they were removed in 3.0.0). They are deprecated because settings were spread across four static mutables with load-order rules that were easy to get wrong — `setLogging` after the first `instance()` call, for instance, silently did nothing.

**Before:**

```dart
ApiServices.configure(
  getToken: () => storage.read(key: 'access_token'),
  onTokenRefresh: () => authRepository.refresh(),
  onRefreshFailed: () => authController.logout(),
  bypassConnectivityCheck: true,
  refreshTimeout: const Duration(seconds: 20),
  logging: const ApiLogOptions(requestHeader: true),
);
```

**After:**

```dart
ApiServices.init(ApiConfig(
  baseUrl: 'https://api.example.com',        // new: drop full URLs from call sites
  bypassConnectivityCheck: true,
  logging: const ApiLogOptions(requestHeader: true),
  auth: AuthConfig(
    getToken: () => storage.read(key: 'access_token'),
    onTokenRefresh: () => authRepository.refresh(),
    onRefreshFailed: () => authController.logout(),
    refreshTimeout: const Duration(seconds: 20),
  ),
));
```

For a client with no authentication, `ApiServices.init(const ApiConfig())` is the whole setup — or skip it entirely and let `instance()` build a default.

---

## Worth adopting, in rough order of payoff

### Typed responses

Removes the `fold` → `fromJson` → try/catch block from every repository method.

```dart
// Before
final result = await api.get(endpoint: '/users/1');
return result.fold(
  (failure) => Left(failure),
  (response) {
    try {
      return Right(User.fromJson(response.data));
    } catch (e) {
      return Left(someFailure);
    }
  },
);

// After
return api.getAs<User>(endpoint: '/users/1', parser: User.fromJson);
```

A parser that throws becomes a `Failure` with `ErrorSource.parseError`, carrying the raw body in `failure.data` so you can see what actually arrived.

For lists: `parser: listParser(User.fromJson)`, or `listParser(User.fromJson, key: 'data')` for a `{"data": [...]}` wrapper.

### Field-level validation errors

```dart
result.fold(
  (failure) {
    final fields = failure.validationErrors;   // {"email": ["already taken"]}
    if (fields != null) {
      emailError.value = fields['email']?.first;
    } else {
      showSnackBar(failure.message);
    }
  },
  (user) => ...,
);
```

### Offline tolerance

> Response caching was removed in 4.0.0. This section applies to 2.x and 3.x only.

```dart
final result = await api.get(
  endpoint: '/products',
  cachePolicy: CachePolicy.networkFirst,
);

result.fold(
  (failure) => showError(failure.message),
  (response) {
    if (response.isFromCache) showBanner('Offline — showing saved data');
    render(response.data);
  },
);
```

> Cached entries are **not** scoped per user. Call `ApiCacheHelper.instance.clearAllCache()` on logout, or the next user will read the previous one's responses.

If caching has no place in your app at all, say so once and stop worrying about it — this overrides any `cachePolicy` a call site passes and never opens the database:

```dart
ApiServices.init(const ApiConfig(cacheEnabled: false));
```

### One place for error reporting

Instead of reporting from every `fold`:

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

### Base64 in logs

If you already wrap `logPrint` to strip base64 out of the log stream, that keeps working untouched — the hook is unchanged. The package now ships the same thing built in, so you can drop your local copy:

```dart
// Before — your own sink
logging: ApiLogOptions(requestBody: false, logPrint: trimApiLog),

// After
logging: const ApiLogOptions(requestBody: false, trimBase64: true),
```

Both compose: with `trimBase64: true` *and* a custom `logPrint`, your sink receives lines that have already been trimmed. Tune with `Base64LogTrimmer(sink: ..., minRunLength: 60).call` if the default swallows identifiers you need.

### Testing consumers

```dart
import 'package:baaba_api_handler/testing.dart';

final api = FakeApiServices()
  ..stubJson(HttpMethod.get, '/users/1', {'id': 1, 'name': 'Ada'});

expect(await UserRepository(api).find(1), isA<User>());
expect(api.recordedCalls.single.endpoint, '/users/1');
```

Add `ApiServices.reset()` to your `tearDown` so configuration does not leak between tests.

---

## Deprecated API reference

| 1.x | 2.0.0 |
| --- | --- |
| `ApiServices.configure(getToken:, onTokenRefresh:, ...)` | `ApiServices.init(ApiConfig(auth: AuthConfig(...)))` |
| `ApiServices.setConnectivityCheck(enabled: false)` | `ApiServices.init(ApiConfig(bypassConnectivityCheck: true))` |
| `ApiServices.setLogging(options)` | `ApiServices.init(ApiConfig(logging: options))` |
| `DioFactory().getDio(header:, logOptions:)` | `DioFactory().getDio(config: ApiConfig(...))` |
| `NetworkRetryInterceptor(maxRetries:, retryInterval:)` | `NetworkRetryInterceptor(policy: RetryPolicy(...))` |

`configureLoader` is unchanged.
