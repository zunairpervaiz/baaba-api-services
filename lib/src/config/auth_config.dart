import 'dart:async';

import 'package:baaba_api_handler/src/config/refresh_outcome.dart';
import 'package:dio/dio.dart';

/// Token-based authentication settings for `ApiServices`.
///
/// Supplying this to `ApiConfig.auth` attaches the token refresh interceptor,
/// which adds auth headers to every request and transparently refreshes the
/// token on a `401`. Omit it and no auth interceptor is installed at all —
/// `401`s then surface as an ordinary `Failure`.
///
/// **Example:**
///
/// ```dart
/// ApiServices.init(ApiConfig(
///   baseUrl: 'https://api.example.com',
///   auth: AuthConfig(
///     getToken: () => storage.read(key: 'access_token'),
///     onTokenRefresh: () => authRepository.refresh(),
///     onRefreshFailed: () => authController.logout(),
///   ),
/// ));
/// ```
class AuthConfig {
  /// Returns the current auth token. Called before every outgoing request, so
  /// read it from storage rather than caching it here.
  ///
  /// Returning `null` sends the request without auth headers.
  final Future<String?> Function() getToken;

  /// Performs the actual refresh — typically calls your `/auth/refresh`
  /// endpoint and persists the new token.
  ///
  /// Return `true` if a fresh token is now available from [getToken], `false`
  /// otherwise. Throwing is treated the same as returning `false`.
  ///
  /// `false` always ends the session, even when the refresh only failed
  /// because the device was offline. Use [refreshSession] instead to keep the
  /// session through a refresh that could not be tried. Supply exactly one of
  /// the two.
  final Future<bool> Function()? onTokenRefresh;

  /// Performs the refresh, saying *why* it failed when it does.
  ///
  /// The alternative to [onTokenRefresh] for a backend whose refresh call can
  /// fail for reasons that do not end the session:
  ///
  /// ```dart
  /// refreshSession: () async {
  ///   try {
  ///     await authRepository.refresh();
  ///     return RefreshOutcome.refreshed;
  ///   } on DioException catch (e) {
  ///     final status = e.response?.statusCode;
  ///     return status == 400 || status == 401 || status == 403
  ///         ? RefreshOutcome.sessionExpired
  ///         : RefreshOutcome.failed;
  ///   }
  /// },
  /// ```
  ///
  /// Only [RefreshOutcome.sessionExpired] fires [onRefreshFailed]. Throwing is
  /// treated as [RefreshOutcome.failed]: an exception says the refresh broke,
  /// not that the server refused it.
  final Future<RefreshOutcome> Function()? refreshSession;

  /// Called when the session is over: [onTokenRefresh] returned `false` or
  /// threw, or [refreshSession] returned [RefreshOutcome.sessionExpired]. Use
  /// it to log the user out or navigate to the login screen.
  final void Function()? onRefreshFailed;

  /// Whether the saved token has expired, or is about to.
  ///
  /// When set, it is asked before each request that would carry the token,
  /// and a `true` refreshes first, so the request goes out with a good token
  /// instead of spending a round trip on a `401`. Concurrent requests share
  /// the one refresh, exactly as concurrent `401`s do.
  ///
  /// ```dart
  /// isTokenExpired: () async {
  ///   final expiresAt = await storage.readExpiry();
  ///   // A little early, so the token does not die on the way.
  ///   return expiresAt != null &&
  ///       DateTime.now().add(const Duration(seconds: 30)).isAfter(expiresAt);
  /// },
  /// ```
  ///
  /// When that refresh ends the session, the request is not sent and fails as
  /// a `401` (`ErrorSource.unauthorized`). When it merely fails, the request
  /// goes out with the token it has and the server decides; a `401` for it
  /// does not try the refresh again.
  ///
  /// Not asked for requests matched by [skipRefresh], nor for requests made
  /// from inside the refresh itself. A throw counts as "not expired" — the
  /// server's `401` is the backstop.
  final FutureOr<bool> Function()? isTokenExpired;

  /// Requests whose `401` must not trigger a refresh.
  ///
  /// A `401` from the login endpoint means a wrong password, not an expired
  /// session. Without this, it starts a refresh that has nothing to refresh,
  /// which fails and fires [onRefreshFailed] — logging the user "out" of the
  /// login screen. Logout belongs here too: it must complete even when the
  /// session has already gone.
  ///
  /// ```dart
  /// skipRefresh: (options) => const {
  ///   '/auth/login',
  ///   '/auth/refresh',
  ///   '/auth/logout',
  /// }.contains(options.path),
  /// ```
  ///
  /// Matched requests still carry the token if there is one — logout usually
  /// needs it — and their `401` surfaces as an ordinary `Failure`. They are
  /// never held for [isTokenExpired] either. A predicate that throws is
  /// treated as `false`.
  final bool Function(RequestOptions options)? skipRefresh;

  /// Builds the auth headers merged into every request.
  ///
  /// Defaults to `{'Authorization': 'Bearer <token>'}`. Override it for a
  /// different scheme or to add companion headers:
  ///
  /// ```dart
  /// headerBuilder: (token) => {
  ///   'Authorization': 'Bearer $token',
  ///   'X-Tenant-Id': 'my-org',
  /// },
  /// ```
  final Map<String, String> Function(String token)? headerBuilder;

  /// Decides which hosts the token may be sent to.
  ///
  /// **Not every host the client talks to should get the token.**
  /// `ApiConfig.baseUrl` supports absolute endpoints so a single client can
  /// reach a CDN or a third-party, which means a bearer token intended for
  /// your API can travel to `s3.amazonaws.com` or an analytics host purely
  /// because the call went out through the same client. It also *breaks*
  /// presigned URLs: S3 rejects a request that carries both a presigned
  /// signature and an `Authorization` header.
  ///
  /// Defaults to "same host as `ApiConfig.baseUrl`". Supply a predicate to
  /// span several hosts you own:
  ///
  /// ```dart
  /// sendTokenTo: (uri) => uri.host.endsWith('.mycompany.com'),
  /// ```
  ///
  /// Comparison is by host, so a different port or scheme on the same host
  /// still receives the token — use a predicate if that matters. When
  /// `baseUrl` is not set there is nothing to compare against and the token
  /// is sent everywhere, which is the pre-existing behaviour.
  ///
  /// A predicate that throws is treated as "do not send": a broken check must
  /// not leak the token.
  final bool Function(Uri uri)? sendTokenTo;

  /// Bounds how long a request that `401`s while a refresh is already in
  /// flight waits for that refresh before giving up — a safety net for an
  /// [onTokenRefresh] that never completes.
  ///
  /// A refresh request made through this client that itself `401`s (an
  /// expired refresh token) does not wait here: it fails at once, so the
  /// refresh reports failure and [onRefreshFailed] fires without delay.
  final Duration refreshTimeout;

  const AuthConfig({
    required this.getToken,
    this.onTokenRefresh,
    this.refreshSession,
    this.onRefreshFailed,
    this.isTokenExpired,
    this.skipRefresh,
    this.headerBuilder,
    this.sendTokenTo,
    this.refreshTimeout = const Duration(seconds: 30),
  }) : assert(
         (onTokenRefresh == null) != (refreshSession == null),
         'Supply exactly one of onTokenRefresh and refreshSession.',
       );

  /// Returns a copy with the given fields replaced.
  ///
  /// Only replaces — passing `null` is indistinguishable from omitting the
  /// argument, so it cannot remove [onRefreshFailed], [isTokenExpired],
  /// [skipRefresh], [headerBuilder] or [sendTokenTo]. Build a fresh
  /// [AuthConfig] for that.
  ///
  /// Passing one of [onTokenRefresh] and [refreshSession] replaces whichever
  /// of the two the original had.
  AuthConfig copyWith({
    Future<String?> Function()? getToken,
    Future<bool> Function()? onTokenRefresh,
    Future<RefreshOutcome> Function()? refreshSession,
    void Function()? onRefreshFailed,
    FutureOr<bool> Function()? isTokenExpired,
    bool Function(RequestOptions options)? skipRefresh,
    Map<String, String> Function(String token)? headerBuilder,
    bool Function(Uri uri)? sendTokenTo,
    Duration? refreshTimeout,
  }) {
    return AuthConfig(
      getToken: getToken ?? this.getToken,
      onTokenRefresh:
          onTokenRefresh ??
          (refreshSession == null ? this.onTokenRefresh : null),
      refreshSession:
          refreshSession ??
          (onTokenRefresh == null ? this.refreshSession : null),
      onRefreshFailed: onRefreshFailed ?? this.onRefreshFailed,
      isTokenExpired: isTokenExpired ?? this.isTokenExpired,
      skipRefresh: skipRefresh ?? this.skipRefresh,
      headerBuilder: headerBuilder ?? this.headerBuilder,
      sendTokenTo: sendTokenTo ?? this.sendTokenTo,
      refreshTimeout: refreshTimeout ?? this.refreshTimeout,
    );
  }
}
