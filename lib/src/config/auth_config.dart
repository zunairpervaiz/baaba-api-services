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
    this.refreshTimeout = const Duration(seconds: 30),
  });

  AuthConfig copyWith({
    Future<String?> Function()? getToken,
    Future<bool> Function()? onTokenRefresh,
    void Function()? onRefreshFailed,
    Map<String, String> Function(String token)? headerBuilder,
    Duration? refreshTimeout,
  }) {
    return AuthConfig(
      getToken: getToken ?? this.getToken,
      onTokenRefresh: onTokenRefresh ?? this.onTokenRefresh,
      onRefreshFailed: onRefreshFailed ?? this.onRefreshFailed,
      headerBuilder: headerBuilder ?? this.headerBuilder,
      refreshTimeout: refreshTimeout ?? this.refreshTimeout,
    );
  }
}
