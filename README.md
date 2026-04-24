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
    - [Cancel Request](#17-cancel-request)
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
  baaba_api_handler: ^1.0.7
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

Provides typed HTTP methods with built-in network checks, automatic token refresh, network retry, and structured error responses.

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

| Parameter        | Type                                    | Required | Description                                                                          |
| ---------------- | --------------------------------------- | -------- | ------------------------------------------------------------------------------------ |
| `getToken`       | `Future<String?> Function()`            | Yes      | Returns the current token. Called before every outgoing request.                     |
| `onTokenRefresh` | `Future<bool> Function()`               | Yes      | Performs the token refresh. Returns `true` on success.                               |
| `onRefreshFailed`| `void Function()?`                      | No       | Called when refresh fails (e.g. to trigger logout).                                  |
| `headerBuilder`  | `Map<String, String> Function(String)?` | No       | Builds auth headers from the token. Defaults to `Authorization: Bearer <token>`.     |

> If you do not need token auth, skip this and call `ApiServices.instance()` directly.

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

#### 1.7 Cancel Request

Cancel the most recent in-flight request:

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
```

| Parameter | Type     | Required | Description                              |
| --------- | -------- | -------- | ---------------------------------------- |
| `url`     | `String` | Yes      | The URL whose cached response to fetch.  |

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
