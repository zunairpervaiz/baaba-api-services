import 'package:baaba_api_handler/src/config/auth_config.dart';
import 'package:baaba_api_handler/src/config/pinning_config.dart';
import 'package:baaba_api_handler/src/config/proxy_config.dart';
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

  /// Decides whether a `2xx` response actually represents success.
  ///
  /// Some APIs answer `200 OK` with `{"success": false, "message": "..."}`.
  /// Without this, those land in `Right` and every caller has to re-check the
  /// body. Return `false` and the package converts the response into a
  /// `Failure`, extracting the message from the body the same way it does for
  /// a real error response.
  ///
  /// Not applied to `head()` or `download()`: neither has a body in
  /// `response.data` to judge.
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

  /// Rewrites a [Failure] before the caller sees it — the one place to turn
  /// the package's generic failures into your app's own.
  ///
  /// Called for every `Left` the client returns: HTTP errors, timeouts, the
  /// offline short-circuit, cancellation, parse errors, and bodies rejected by
  /// [isSuccess] (after [onRejected]). Return `null` to keep the failure as
  /// it is.
  ///
  /// ```dart
  /// mapFailure: (failure) {
  ///   // A 401 from login is a wrong password, not an expired session.
  ///   if (failure.statusCode == 401 &&
  ///       failure.requestOptions?.path == '/auth/login') {
  ///     return Failure(
  ///       ErrorSource.unauthorized,
  ///       ResponseCode.unauthorized,
  ///       'Wrong username or password.',
  ///       data: failure.data,
  ///       statusCode: 401,
  ///     );
  ///   }
  ///   // {"code": "ACCOUNT_LOCKED", ...} in the body.
  ///   if (failure.errorCode == 'ACCOUNT_LOCKED') {
  ///     return Failure(
  ///       failure.errorType,
  ///       failure.code,
  ///       'Your account is locked. Contact HR.',
  ///       data: failure.data,
  ///       statusCode: failure.statusCode,
  ///     );
  ///   }
  ///   return null;
  /// },
  /// ```
  ///
  /// A returned failure without `requestOptions` gets the original's, so the
  /// observer still knows which call it was. The observer sees the mapped
  /// failure. Must not throw — one that does leaves the failure unchanged.
  final Failure? Function(Failure failure)? mapFailure;

  /// Replaces Dio's default HTTP adapter — the transport itself.
  ///
  /// For pinning, prefer [pinning]; this is the escape hatch for anything it
  /// does not cover, and for a fake adapter in tests. Mutually exclusive with
  /// [pinning] and [proxy], since all three decide which adapter sends the
  /// request.
  final HttpClientAdapter? httpClientAdapter;

  /// Certificate pinning by CA, per host. See [PinningConfig].
  ///
  /// Applies on Android, iOS and desktop. Ignored on web, where the browser
  /// owns TLS and offers no way to restrict it.
  final PinningConfig? pinning;

  /// Routes selected hosts through an HTTP proxy, everything else direct.
  /// Works with [pinning]: `https` is tunnelled, and the certificate is still
  /// verified against the pinned roots. See [ProxyConfig].
  ///
  /// Applies on Android, iOS and desktop. Ignored on web.
  final ProxyConfig? proxy;

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
  /// slots free up. The cap governs actual network calls: a request
  /// collapsed by de-duplication does not consume a slot of its own. A queued
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
    this.isSuccess,
    this.onRejected,
    this.mapFailure,
    this.httpClientAdapter,
    this.pinning,
    this.proxy,
    this.observer,
    this.interceptors = const [],
    this.maxConcurrentRequests,
    this.auth,
  }) : assert(
         maxConcurrentRequests == null || maxConcurrentRequests > 0,
         'maxConcurrentRequests must be positive, or null for no cap — '
         'a cap of 0 would queue every request forever.',
       ),
       assert(
         httpClientAdapter == null || (pinning == null && proxy == null),
         'httpClientAdapter replaces the transport that pinning and proxy '
         'configure. Use one or the other.',
       );

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
    bool Function(Response response)? isSuccess,
    Failure? Function(Response response)? onRejected,
    Failure? Function(Failure failure)? mapFailure,
    HttpClientAdapter? httpClientAdapter,
    PinningConfig? pinning,
    ProxyConfig? proxy,
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
      isSuccess: isSuccess ?? this.isSuccess,
      onRejected: onRejected ?? this.onRejected,
      mapFailure: mapFailure ?? this.mapFailure,
      httpClientAdapter: httpClientAdapter ?? this.httpClientAdapter,
      pinning: pinning ?? this.pinning,
      proxy: proxy ?? this.proxy,
      observer: observer ?? this.observer,
      interceptors: interceptors ?? this.interceptors,
      maxConcurrentRequests:
          maxConcurrentRequests ?? this.maxConcurrentRequests,
      auth: auth ?? this.auth,
    );
  }
}
