# baaba_api_handler

A Flutter package for HTTP API communication and response caching. Wraps [Dio](https://pub.dev/packages/dio) with structured error handling, automatic token refresh, network retry, and local cache management.

## Table of Contents

- [Installation](#installation)
- [Features](#features)
  - [Network API Handler](#1-network-api-handler)
    - [Configuration (Token Auth)](#11-configuration-token-auth)
    - [GET](#12-get)
    - [POST](#13-post)
    - [PUT](#14-put)
    - [PATCH](#15-patch)
    - [DELETE](#16-delete)
    - [Download](#17-download)
    - [Cancel Request](#18-cancel-request)
  - [API Cache Management](#2-api-cache-management)
    - [Get Cache](#21-get-cache)
    - [Set Cache](#22-set-cache)
    - [Clear Cache](#23-clear-cache)
    - [Cache Exists](#24-cache-exists)
    - [Clear All Cache](#25-clear-all-cache)

---

## Installation

#### 1. Add Dependency

Add to your `pubspec.yaml`:

```yaml
dependencies:
  baaba_api_handler: ^1.3.0
```

#### 2. Install Packages

```bash
flutter pub get
```

#### 3. Import the Library

```dart
import 'package:baaba_api_handler/ts_api_handler.dart';
```

> `Response`, `CancelToken` (Dio), and `APICacheDBModel` are re-exported from this single import — no need to add `dio` or `api_cache_manager` as direct dependencies.

---

## Features

### 1. Network API Handler

Provides typed HTTP methods with built-in network checks, automatic token refresh, network retry, and structured error responses (automatically extracting `message` or `detail` keys from error bodies).

Transient timeouts/connection errors are auto-retried (up to 3 times, exponential backoff) only for idempotent methods — `GET`, `PUT`, `DELETE` — since retrying `POST`/`PATCH` could duplicate a side effect the server already processed before the timeout.

Create a singleton instance:

```dart
final apiServices = ApiServices.instance();
```

#### Request Parameters

All HTTP methods share these parameters:

| Parameter          | Type                | Required | Description                                            |
| ------------------ | ------------------- | -------- | ------------------------------------------------------ |
| `endpoint`         | `String`            | Yes      | Full URL of the API endpoint.                          |
| `data`             | `Object?`           | No       | Request body.                                          |
| `params`           | `Map<String, dynamic>?` | No   | Query parameters.                                      |
| `headers`          | `Map<String, String>?`  | No   | Custom headers. Defaults to `application/json`.        |
| `receiveTimeout`   | `Duration?`         | No       | Timeout for receiving a response.                      |
| `sendTimeout`      | `Duration?`         | No       | Timeout for sending the request.                       |
| `cancelToken`      | `CancelToken?`      | No       | Token to cancel this specific request.                 |
| `onSendProgress`   | `ProgressCallback?` | No       | Upload progress callback.                              |
| `onReceiveProgress`| `ProgressCallback?` | No       | Download progress callback.                            |

All methods return `Either<Failure, Response>`:

```dart
response.fold(
  (failure) => print('Error ${failure.message}'),
  (success) => print(success.data),
);
```

| Type      | Description                                                      |
| --------- | ---------------------------------------------------------------- |
| `Failure` | Contains `errorSource`, `responseCode`, and `message`.          |
| `Response`| Dio response with `data`, `statusCode`, and `headers`.          |

---

#### 1.1 Configuration (Token Auth)

Call `ApiServices.configure()` once at app startup to enable automatic token injection and refresh on 401 responses:

```dart
ApiServices.configure(
  getToken: () async => await storage.read(key: 'access_token'),
  onTokenRefresh: () async {
    // Perform your refresh logic here.
    // Return true if the token was refreshed successfully.
    return await authRepository.refresh();
  },
  onRefreshFailed: () {
    // Called when refresh fails — typically trigger logout.
    authController.logout();
  },
);
```

| Parameter                  | Type                                    | Required | Description                                                                                                                  |
| -------------------------- | --------------------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `getToken`                 | `Future<String?> Function()`            | Yes      | Returns the current token. Called before every outgoing request.                                                             |
| `onTokenRefresh`           | `Future<bool> Function()`               | Yes      | Performs the token refresh. Returns `true` on success.                                                                       |
| `onRefreshFailed`          | `void Function()?`                      | No       | Called when refresh fails (e.g. to trigger logout).                                                                          |
| `headerBuilder`            | `Map<String, String> Function(String)?` | No       | Builds auth headers from the token. Defaults to `Authorization: Bearer <token>`.                                             |
| `bypassConnectivityCheck`  | `bool`                                  | No       | Skip the pre-flight internet connectivity check. Use in staging or internal environments where connectivity probes always fail due to proxies or firewalls. Defaults to `false`. |
| `refreshTimeout`           | `Duration`                              | No       | How long a request that 401s while another refresh is already in flight waits for that refresh before giving up and failing with the original error. Defaults to 30 seconds. |
| `logging`                  | `ApiLogOptions`                         | No       | What the console logger prints. Defaults to `const ApiLogOptions()` (request line, request body, response body, errors). See [Logging](#logging). |

> If you do not need token auth, skip this and call `ApiServices.instance()` directly.

Requests that 401 while a refresh triggered by another request is already running wait for that same refresh to finish and retry with the fresh token — they don't fail outright just for losing the race. If the refresh itself doesn't resolve within `refreshTimeout` (e.g. the refresh endpoint's own call is stuck), the waiting request gives up and surfaces its original 401 as a `Failure`.

#### Custom Headers with `headerBuilder`

By default the token is injected as `Authorization: Bearer <token>`. Use `headerBuilder` when you need a different scheme or additional headers:

```dart
// Different auth scheme
ApiServices.configure(
  getToken: () async => await storage.read(key: 'token'),
  onTokenRefresh: () async => await authRepo.refresh(),
  headerBuilder: (token) => {
    'Authorization': 'Token $token',
  },
);
```

```dart
// Multiple fields — token + tenant ID + API key
ApiServices.configure(
  getToken: () async => await storage.read(key: 'token'),
  onTokenRefresh: () async => await authRepo.refresh(),
  headerBuilder: (token) => {
    'Authorization': 'Bearer $token',
    'X-Tenant-Id': 'my-org',
    'X-Api-Key': 'abc123',
  },
);
```

The returned map is merged into every request's headers, including automatic retries after a token refresh.

#### Bypass Connectivity Check

On internal or staging networks where external connectivity probes always fail (e.g. behind a proxy or firewall), pass `bypassConnectivityCheck: true` to skip the pre-flight check:

```dart
// Staging entry point — internal network with proxy
ApiServices.configure(
  getToken: () async => await storage.read(key: 'access_token'),
  onTokenRefresh: () async => await authRepository.refresh(),
  onRefreshFailed: () => authController.logout(),
  bypassConnectivityCheck: true,
);
```

If you don't need token auth but still need to disable the connectivity check, use `setConnectivityCheck`:

```dart
// Before configureDependencies() in your staging entry point
ApiServices.setConnectivityCheck(enabled: false);
```

| Parameter | Type   | Default | Description                                                   |
| --------- | ------ | ------- | ------------------------------------------------------------- |
| `enabled` | `bool` | `true`  | Set to `false` to skip the check; `true` to re-enable it.    |

#### Logging

In non-release builds every request is printed to the console. Pass an `ApiLogOptions` to decide what shows up:

```dart
ApiServices.configure(
  getToken: () async => await storage.read(key: 'access_token'),
  onTokenRefresh: () async => await authRepository.refresh(),
  logging: const ApiLogOptions(
    requestBody: false,    // don't print passwords / PII
    requestHeader: true,   // but do show the Authorization header
    responseBody: false,   // responses are large and noisy
  ),
);
```

| Field           | Type                        | Default | Description                                                                       |
| --------------- | --------------------------- | ------- | --------------------------------------------------------------------------------- |
| `enabled`       | `bool`                      | `true`  | Master switch. When `false` no logger is attached and every other field is ignored. |
| `request`       | `bool`                      | `true`  | The request line — method and URL.                                                |
| `requestHeader` | `bool`                      | `false` | Request headers and query parameters. Includes `Authorization`.                   |
| `requestBody`   | `bool`                      | `true`  | The request body. Never printed for `GET` regardless of this flag.                |
| `responseHeader`| `bool`                      | `false` | Response headers.                                                                 |
| `responseBody`  | `bool`                      | `true`  | The response body.                                                                |
| `error`         | `bool`                      | `true`  | Errors, including non-2xx responses.                                              |
| `maxWidth`      | `int`                       | `90`    | Line width before wrapping.                                                       |
| `compact`       | `bool`                      | `true`  | Print JSON compactly instead of one node per line.                                |
| `logPrint`      | `void Function(Object)?`    | `print` | Where log lines go — e.g. `debugPrint` to dodge Android log truncation, or a file sink. |

To silence logging completely, even in debug:

```dart
logging: const ApiLogOptions.disabled(),
```

Without token auth, use `setLogging` instead — call it before the first `ApiServices.instance()`, since the Dio client and its logger are built once and cached:

```dart
ApiServices.setLogging(const ApiLogOptions(requestBody: false));
```

`copyWith` is available if you keep a base config per environment:

```dart
const base = ApiLogOptions(requestBody: false);
ApiServices.setLogging(base.copyWith(requestHeader: true));  // debugging auth
```

> Release builds never attach the logger at all, so these options only change what you see while developing.

---

#### 1.2 GET

```dart
final response = await apiServices.get(endpoint: 'https://api.example.com/users');
```

#### 1.3 POST

```dart
final response = await apiServices.post(
  endpoint: 'https://api.example.com/users',
  data: {'name': 'Baaba'},
);
```

#### 1.4 PUT

```dart
final response = await apiServices.put(
  endpoint: 'https://api.example.com/users/1',
  data: {'name': 'Baaba Updated'},
);
```

#### 1.5 PATCH

```dart
final response = await apiServices.patch(
  endpoint: 'https://api.example.com/users/1',
  data: {'name': 'Baaba Patched'},
);
```

#### 1.6 DELETE

```dart
final response = await apiServices.delete(endpoint: 'https://api.example.com/users/1');
```

#### 1.7 Download

Streams a file response directly to disk instead of loading it into memory — use for images, PDFs, exports, or any file response.

```dart
final dir = await getApplicationDocumentsDirectory();
final response = await apiServices.download(
  endpoint: 'https://api.example.com/files/report.pdf',
  savePath: '${dir.path}/report.pdf',
  onReceiveProgress: (received, total) => print('${received / total * 100}%'),
);

response.fold(
  (failure) => print('Error ${failure.message}'),
  (_) => openFile('${dir.path}/report.pdf'),
);
```

| Parameter          | Type                | Required | Description                                            |
| ------------------ | ------------------- | -------- | ------------------------------------------------------ |
| `endpoint`         | `String`            | Yes      | Full URL of the file to download.                       |
| `savePath`         | `String`            | Yes      | Local path to write the downloaded file to.             |
| `params`           | `Map<String, dynamic>?` | No   | Query parameters.                                       |
| `headers`          | `Map<String, String>?`  | No   | Custom headers.                                         |
| `receiveTimeout`   | `Duration?`         | No       | Timeout for receiving the response.                     |
| `sendTimeout`      | `Duration?`         | No       | Timeout for sending the request.                        |
| `cancelToken`      | `CancelToken?`      | No       | Token to cancel this specific download.                 |
| `onReceiveProgress`| `ProgressCallback?` | No       | Download progress callback.                             |
| `deleteOnError`    | `bool`              | No       | Delete the partially-written file if the download fails. Defaults to `true`. |
| `showLoader`       | `bool`              | No       | Show the global loading indicator for this call. Defaults to `true`. |

#### 1.8 Cancel Request

Cancel all in-flight requests at once:

```dart
apiServices.cancelRequest();

// With an optional reason:
apiServices.cancelRequest(cancellationReason: 'User navigated away');
```

To cancel a specific request, pass a `CancelToken` when making the call:

```dart
final token = CancelToken();
final response = await apiServices.get(endpoint: url, cancelToken: token);

// Later:
token.cancel('Cancelled by user');
```

---

### 2. API Cache Management

Caches API responses in a local SQLite database to reduce unnecessary network calls and support offline-first behaviour.

```dart
final apiCacheHelper = ApiCacheHelper.instance;
```

#### 2.1 Get Cache

```dart
final cached = await apiCacheHelper.getCacheData(url);

// With a freshness window — entries older than 5 minutes are treated as a
// miss (and cleared) instead of being returned stale:
final fresh = await apiCacheHelper.getCacheData(url, maxAge: const Duration(minutes: 5));
```

| Parameter | Type       | Required | Description                                                            |
| --------- | ---------- | -------- | ------------------------------------------------------------------------ |
| `url`     | `String`   | Yes      | The URL whose cached response to fetch.                                |
| `maxAge`  | `Duration?`| No       | If the cached entry is older than this, it's cleared and `null` is returned instead of stale data. Omit to return cached data regardless of age. |

#### 2.2 Set Cache

```dart
final stored = await apiCacheHelper.setCacheData(url, data);
```

| Parameter | Type     | Required | Description                          |
| --------- | -------- | -------- | ------------------------------------ |
| `url`     | `String` | Yes      | The URL to associate with the cache. |
| `data`    | `String` | Yes      | The response data to cache.          |

#### 2.3 Clear Cache

```dart
final cleared = await apiCacheHelper.clearCache(url);
```

| Parameter | Type     | Required | Description                            |
| --------- | -------- | -------- | -------------------------------------- |
| `url`     | `String` | Yes      | The URL whose cache entry to remove.   |

#### 2.4 Cache Exists

```dart
final exists = await apiCacheHelper.isCacheExist(url);
```

| Parameter | Type     | Required | Description                               |
| --------- | -------- | -------- | ----------------------------------------- |
| `url`     | `String` | Yes      | The URL to check for a cached response.   |

#### 2.5 Clear All Cache

```dart
await apiCacheHelper.clearAllCache();
```
