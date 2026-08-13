import 'package:baaba_api_handler/src/config/auth_config.dart';
import 'package:baaba_api_handler/src/config/cache_policy.dart';
import 'package:baaba_api_handler/src/config/retry_policy.dart';
import 'package:baaba_api_handler/src/observer/api_observer.dart';
import 'package:baaba_api_handler/src/utils/api_log_options.dart';
import 'package:dio/dio.dart';

/// Everything `ApiServices` needs, in one object.
///
/// Pass it to `ApiServices.init` once at app startup, before any request:
///
/// ```dart
/// void main() {
///   ApiServices.init(ApiConfig(
///     baseUrl: 'https://api.example.com',
///     auth: AuthConfig(
///       getToken: () => storage.read(key: 'access_token'),
///       onTokenRefresh: () => authRepository.refresh(),
///       onRefreshFailed: () => authController.logout(),
///     ),
///   ));
///   runApp(const MyApp());
/// }
/// ```
///
/// Every field has a default, so `ApiServices.init(const ApiConfig())` is
/// valid and gives you a plain client with sane timeouts and no auth.
///
/// Environments usually differ in only a field or two — build one base config
/// and [copyWith] the rest:
///
/// ```dart
/// const base = ApiConfig(connectTimeout: Duration(seconds: 20));
///
/// // staging: internal network, connectivity probe is blocked by the proxy
/// ApiServices.init(base.copyWith(
///   baseUrl: 'https://staging.example.com',
///   bypassConnectivityCheck: true,
/// ));
/// ```
class ApiConfig {
  /// Prefix for every relative `endpoint`, e.g. `https://api.example.com`.
  ///
  /// With this set, call sites pass `endpoint: '/users'` instead of the full
  /// URL. Endpoints that are already absolute are used as-is, so mixing the
  /// two is safe — handy for hitting a CDN or a third-party host from the same
  /// client.
  final String? baseUrl;

  /// How long to wait for the connection to be established.
  ///
  /// > Before 2.0.0 no timeout was set at any layer, so a request to an
  /// > unreachable-but-not-refusing host hung until the OS gave up. If you
  /// > have an endpoint that legitimately takes longer than this, raise it
  /// > here or per-request rather than removing the bound.
  final Duration connectTimeout;

  /// How long to wait between chunks of the response body.
  ///
  /// Overridable per request — raise it for slow exports and report
  /// generation rather than raising it globally.
  final Duration receiveTimeout;

  /// How long to wait while sending the request body. Overridable per request;
  /// raise it for large uploads.
  final Duration sendTimeout;

  /// Headers merged into every request.
  ///
  /// Requests that pass their own `headers` replace these rather than merging
  /// with them, matching the pre-2.0.0 behaviour.
  final Map<String, String> defaultHeaders;

  /// Skip the pre-flight internet connectivity check.
  ///
  /// The check pings external hosts, which fails permanently behind some
  /// corporate proxies and firewalls — in those environments every request
  /// would otherwise fail with `noInternetConnection` despite the API being
  /// perfectly reachable.
  final bool bypassConnectivityCheck;

  /// How long a connectivity result stays good for.
  ///
  /// The probe is a real network round-trip. Running it before *every*
  /// request roughly doubles the latency of a fast API call, so the result is
  /// reused for this long. Set to [Duration.zero] to probe every time.
  final Duration connectivityCacheTtl;

  /// What the console logger prints. Only applies outside release builds —
  /// no logger is ever attached in release.
  final ApiLogOptions logging;

  /// How transient failures are retried. Use `RetryPolicy.disabled()` to turn
  /// retries off entirely.
  final RetryPolicy retry;

  /// Master switch for response caching.
  ///
  /// Set to `false` and **no request can cache, whatever it asks for** — an
  /// explicit `cachePolicy` on an individual call is downgraded to
  /// [CachePolicy.networkOnly]. Nothing is read from or written to disk, and
  /// the cache database is never opened.
  ///
  /// This is for projects where caching responses is not merely unwanted but
  /// not allowed — anything handling payment, health, or identity data, where
  /// "no response body is persisted to disk" is a requirement rather than a
  /// preference. Leaving it `true` and simply not passing a `cachePolicy` also
  /// results in no caching, but it relies on every call site getting it right;
  /// this does not.
  final bool cacheEnabled;

  /// The [CachePolicy] used by `get`/`getAs` when the call site doesn't name
  /// one.
  ///
  /// Defaults to [CachePolicy.networkOnly] — no caching, the 1.x behaviour.
  /// Set it to make caching the norm for a project without annotating every
  /// call:
  ///
  /// ```dart
  /// // Every GET tolerates going offline; individual calls can still opt out
  /// // with `cachePolicy: CachePolicy.networkOnly`.
  /// ApiServices.init(const ApiConfig(
  ///   defaultCachePolicy: CachePolicy.networkFirst,
  /// ));
  /// ```
  ///
  /// Ignored entirely when [cacheEnabled] is `false`.
  final CachePolicy defaultCachePolicy;

  /// Decides whether a `2xx` response actually represents success.
  ///
  /// Some APIs answer `200 OK` with `{"success": false, "message": "..."}`.
  /// Without this, those land in `Right` and every caller has to re-check the
  /// body. Return `false` and the package converts the response into a
  /// `Failure`, extracting the message from the body the same way it does for
  /// a real error response.
  ///
  /// ```dart
  /// isSuccess: (response) {
  ///   final data = response.data;
  ///   return data is! Map || data['success'] != false;
  /// },
  /// ```
  ///
  /// Defaults to `null` — every `2xx` is a success.
  final bool Function(Response response)? isSuccess;

  /// Replaces Dio's default HTTP adapter.
  ///
  /// Supply your own to pin certificates, or to route through a debugging
  /// proxy such as Charles or Proxyman. The package deliberately does not ship
  /// an implementation: the `dart:io`-based adapters do not exist on web, and
  /// bundling one would cost this package its platform neutrality. See the
  /// README for a fingerprint-pinning recipe.
  final HttpClientAdapter? httpClientAdapter;

  /// Watches every request, response, and failure — wire it to Sentry,
  /// Crashlytics, or analytics. See [ApiObserver].
  final ApiObserver? observer;

  /// Token auth and automatic refresh on `401`. Omit for an unauthenticated
  /// client. See [AuthConfig].
  final AuthConfig? auth;

  const ApiConfig({
    this.baseUrl,
    this.connectTimeout = const Duration(seconds: 30),
    this.receiveTimeout = const Duration(seconds: 30),
    this.sendTimeout = const Duration(seconds: 30),
    this.defaultHeaders = const {},
    this.bypassConnectivityCheck = false,
    this.connectivityCacheTtl = const Duration(seconds: 5),
    this.logging = const ApiLogOptions(),
    this.retry = const RetryPolicy(),
    this.cacheEnabled = true,
    this.defaultCachePolicy = CachePolicy.networkOnly,
    this.isSuccess,
    this.httpClientAdapter,
    this.observer,
    this.auth,
  });

  /// Returns a copy with the given fields replaced.
  ///
  /// Only replaces — it cannot *clear* a nullable field, because passing
  /// `null` is indistinguishable from omitting the argument. To drop [auth]
  /// on logout, or remove an [observer], build a fresh [ApiConfig] rather
  /// than deriving one:
  ///
  /// ```dart
  /// ApiServices.init(const ApiConfig(baseUrl: 'https://api.example.com'));
  /// ```
  ApiConfig copyWith({
    String? baseUrl,
    Duration? connectTimeout,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? defaultHeaders,
    bool? bypassConnectivityCheck,
    Duration? connectivityCacheTtl,
    ApiLogOptions? logging,
    RetryPolicy? retry,
    bool? cacheEnabled,
    CachePolicy? defaultCachePolicy,
    bool Function(Response response)? isSuccess,
    HttpClientAdapter? httpClientAdapter,
    ApiObserver? observer,
    AuthConfig? auth,
  }) {
    return ApiConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      receiveTimeout: receiveTimeout ?? this.receiveTimeout,
      sendTimeout: sendTimeout ?? this.sendTimeout,
      defaultHeaders: defaultHeaders ?? this.defaultHeaders,
      bypassConnectivityCheck:
          bypassConnectivityCheck ?? this.bypassConnectivityCheck,
      connectivityCacheTtl: connectivityCacheTtl ?? this.connectivityCacheTtl,
      logging: logging ?? this.logging,
      retry: retry ?? this.retry,
      cacheEnabled: cacheEnabled ?? this.cacheEnabled,
      defaultCachePolicy: defaultCachePolicy ?? this.defaultCachePolicy,
      isSuccess: isSuccess ?? this.isSuccess,
      httpClientAdapter: httpClientAdapter ?? this.httpClientAdapter,
      observer: observer ?? this.observer,
      auth: auth ?? this.auth,
    );
  }
}
