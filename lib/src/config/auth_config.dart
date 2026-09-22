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
  final Future<bool> Function() onTokenRefresh;

  /// Called when [onTokenRefresh] returns `false` or throws. Use it to log the
  /// user out or navigate to the login screen.
  final void Function()? onRefreshFailed;

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
  /// **Without this, the token goes to every host the client talks to.**
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
  /// flight waits for that refresh before giving up.
  ///
  /// Without a bound, a refresh endpoint that itself `401`s (expired refresh
  /// token) would deadlock: its own call is queued behind the very refresh it
  /// is part of.
  final Duration refreshTimeout;

  const AuthConfig({
    required this.getToken,
    required this.onTokenRefresh,
    this.onRefreshFailed,
    this.headerBuilder,
    this.sendTokenTo,
    this.refreshTimeout = const Duration(seconds: 30),
  });

  AuthConfig copyWith({
    Future<String?> Function()? getToken,
    Future<bool> Function()? onTokenRefresh,
    void Function()? onRefreshFailed,
    Map<String, String> Function(String token)? headerBuilder,
    bool Function(Uri uri)? sendTokenTo,
    Duration? refreshTimeout,
  }) {
    return AuthConfig(
      getToken: getToken ?? this.getToken,
      onTokenRefresh: onTokenRefresh ?? this.onTokenRefresh,
      onRefreshFailed: onRefreshFailed ?? this.onRefreshFailed,
      headerBuilder: headerBuilder ?? this.headerBuilder,
      sendTokenTo: sendTokenTo ?? this.sendTokenTo,
      refreshTimeout: refreshTimeout ?? this.refreshTimeout,
    );
  }
}
