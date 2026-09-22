import 'package:baaba_api_handler/src/config/auth_config.dart';
import 'package:baaba_api_handler/src/config/cache_policy.dart';
import 'package:baaba_api_handler/src/config/retry_policy.dart';
import 'package:baaba_api_handler/src/observer/api_observer.dart';
import 'package:baaba_api_handler/src/utils/api_log_options.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
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
  /// A request that passes its own `headers` is merged *over* these rather
  /// than replacing them: keys it does not mention still travel, and keys it
  /// does mention win.
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

  /// Replaces the pre-flight connectivity probe.
  ///
  /// The default probe reaches out to third-party hosts, which is wrong often
  /// enough to matter: corporate networks block it, privacy reviews object to
  /// it, and it says nothing about whether *your* API is reachable. Point it
  /// at your own health endpoint instead:
  ///
  /// ```dart
  /// connectivityProbe: () async {
  ///   try {
  ///     final res = await Dio().head('https://api.example.com/health');
  ///     return res.statusCode == 200;
  ///   } catch (_) {
  ///     return false;
  ///   }
  /// },
  /// ```
  ///
  /// Must not throw — one that does is treated as "offline". Keep it cheap:
  /// it runs before requests, though a positive result is reused for
  /// [connectivityCacheTtl].
  ///
  /// Ignored when [bypassConnectivityCheck] is `true`, which skips the probe
  /// entirely.
  final Future<bool> Function()? connectivityProbe;

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

  /// Caps how many entries the response cache keeps. `null` is unbounded.
  ///
  /// Without a bound the cache only ever grows: every distinct url and query
  /// combination adds a row that nothing removes, and `cacheMaxAge` does not
  /// help — it discards a stale entry when something reads it, so a key that
  /// is never requested again is never reclaimed.
  ///
  /// When a write pushes the cache past the cap, the oldest entries are
  /// deleted until it fits. "Oldest" is by write time, not by last read:
  /// tracking reads would mean a disk write on every cache *hit*, which would
  /// cost more than the eviction saves.
  final int? cacheMaxEntries;

  /// Caps the total size of cached response bodies, in bytes. `null` is
  /// unbounded.
  ///
  /// Applied alongside [cacheMaxEntries] — whichever binds first — and evicts
  /// oldest-first the same way. A single response larger than this is still
  /// stored; the cap governs the total, and refusing to cache a large body
  /// would fail silently in a way that is very hard to notice.
  ///
  /// ```dart
  /// // Keep the cache to roughly 500 entries or 5 MB, whichever comes first.
  /// ApiServices.init(const ApiConfig(
  ///   cacheMaxEntries: 500,
  ///   cacheMaxBytes: 5 * 1024 * 1024,
  /// ));
  /// ```
  final int? cacheMaxBytes;

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

  /// Builds the [Failure] for a response [isSuccess] rejected.
  ///
  /// Without it, every rejected body collapses to the same generic
  /// `badRequest`/`400` failure, so an API that answers `200 OK` with
  /// `{"success": false, "code": "INSUFFICIENT_FUNDS"}` loses the one piece of
  /// information the caller actually needed. Return a failure that carries it:
  ///
  /// ```dart
  /// isSuccess: (r) => r.data is! Map || r.data['success'] != false,
  /// onRejected: (r) => Failure(
  ///   ErrorSource.badRequest,
  ///   ResponseCode.badRequest,
  ///   r.data['message'] as String? ?? 'Request failed',
  ///   data: r.data,
  ///   statusCode: r.statusCode,
  /// ),
  /// ```
  ///
  /// Only consulted when [isSuccess] returns `false`; returning `null` falls
  /// back to the generic failure. Ignored when [isSuccess] is not set, since
  /// nothing is ever rejected then.
  ///
  /// Must not throw — one that does falls back to the generic failure rather
  /// than turning a response into an exception.
  final Failure? Function(Response response)? onRejected;

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

  /// Your own Dio interceptors, added to the chain built by this package.
  ///
  /// [observer] can watch but not change a request; this is the seam for
  /// anything that needs to *modify* one — a correlation id per call, a
  /// tenant header computed at call time, request signing, or a router that
  /// short-circuits to fixtures during local development.
  ///
  /// ```dart
  /// ApiServices.init(ApiConfig(
  ///   interceptors: [
  ///     InterceptorsWrapper(onRequest: (options, handler) {
  ///       options.headers['X-Correlation-Id'] = const Uuid().v4();
  ///       handler.next(options);
  ///     }),
  ///   ],
  /// ));
  /// ```
  ///
  /// **Where these sit in the chain: after auth, before retry.** After auth,
  /// so a signing interceptor sees the `Authorization` header it has to cover
  /// and a header you set cannot be clobbered by the token. Before retry, so
  /// a replayed request still passes through them — a signature carrying a
  /// timestamp is regenerated for each attempt rather than being replayed
  /// stale — and before the logger, so what you add is what gets printed.
  ///
  /// They run in the order given. Applied when the client is built, so
  /// changing them means calling `ApiServices.init` again.
  final List<Interceptor> interceptors;

  /// Caps how many requests may be in flight at once. `null` is unlimited.
  ///
  /// A screen that fires twenty requests on mount sends all twenty at once.
  /// On a mobile connection that saturates the connection pool, so every one
  /// of them reports a worse latency than it would have alone, and it is a
  /// reliable way to trip the server-side rate limiting that [retry] then has
  /// to clean up.
  ///
  /// ```dart
  /// ApiServices.init(const ApiConfig(maxConcurrentRequests: 6));
  /// ```
  ///
  /// Requests past the cap queue in the order they were made and start as
  /// slots free up. The cap governs actual network calls: a cache hit and a
  /// request collapsed by de-duplication do not consume a slot. A queued
  /// request is still cancellable, and still holds the loading indicator —
  /// it is pending, not finished.
  ///
  /// Applied when the client is built, so changing it means calling
  /// `ApiServices.init` again.
  final int? maxConcurrentRequests;

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
    this.connectivityProbe,
    this.logging = const ApiLogOptions(),
    this.retry = const RetryPolicy(),
    this.cacheEnabled = true,
    this.defaultCachePolicy = CachePolicy.networkOnly,
    this.cacheMaxEntries,
    this.cacheMaxBytes,
    this.isSuccess,
    this.onRejected,
    this.httpClientAdapter,
    this.observer,
    this.interceptors = const [],
    this.maxConcurrentRequests,
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
    Future<bool> Function()? connectivityProbe,
    ApiLogOptions? logging,
    RetryPolicy? retry,
    bool? cacheEnabled,
    CachePolicy? defaultCachePolicy,
    int? cacheMaxEntries,
    int? cacheMaxBytes,
    bool Function(Response response)? isSuccess,
    Failure? Function(Response response)? onRejected,
    HttpClientAdapter? httpClientAdapter,
    ApiObserver? observer,
    List<Interceptor>? interceptors,
    int? maxConcurrentRequests,
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
      connectivityProbe: connectivityProbe ?? this.connectivityProbe,
      logging: logging ?? this.logging,
      retry: retry ?? this.retry,
      cacheEnabled: cacheEnabled ?? this.cacheEnabled,
      defaultCachePolicy: defaultCachePolicy ?? this.defaultCachePolicy,
      cacheMaxEntries: cacheMaxEntries ?? this.cacheMaxEntries,
      cacheMaxBytes: cacheMaxBytes ?? this.cacheMaxBytes,
      isSuccess: isSuccess ?? this.isSuccess,
      onRejected: onRejected ?? this.onRejected,
      httpClientAdapter: httpClientAdapter ?? this.httpClientAdapter,
      observer: observer ?? this.observer,
      interceptors: interceptors ?? this.interceptors,
      maxConcurrentRequests:
          maxConcurrentRequests ?? this.maxConcurrentRequests,
      auth: auth ?? this.auth,
    );
  }
}
