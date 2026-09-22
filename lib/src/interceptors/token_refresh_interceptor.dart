import 'dart:async';

import 'package:baaba_api_handler/src/config/auth_config.dart';
import 'package:baaba_api_handler/src/utils/constants.dart';
import 'package:baaba_api_handler/src/utils/replayable_request.dart';
import 'package:dio/dio.dart';

/// A Dio interceptor that automatically attaches auth headers to every request
/// and retries requests that receive a 401 by refreshing the token first.
///
/// Only one refresh runs at a time: if several requests 401 concurrently
/// (e.g. right as the token expires), the first triggers [onTokenRefresh] and
/// the rest wait for that same refresh to finish, then retry with the fresh
/// token — none of them fail outright just for losing the race.
///
/// Use [ApiServices.configure] to set this up — you do not need to instantiate
/// this class directly.
class TokenRefreshInterceptor extends Interceptor {
  /// Returns the current auth token to attach to each request.
  /// Called before every outgoing request.
  final Future<String?> Function() getToken;

  /// Performs the token refresh. Should return `true` if the token was
  /// successfully refreshed, `false` otherwise.
  final Future<bool> Function() onTokenRefresh;

  /// Called when the token refresh fails (e.g. refresh endpoint returns 401
  /// or [onTokenRefresh] throws). Use this to trigger a logout.
  final void Function()? onRefreshFailed;

  /// Builds the auth headers merged into every request from the token value.
  ///
  /// When omitted, defaults to `{'Authorization': 'Bearer <token>'}`.
  ///
  /// **Examples:**
  ///
  /// Custom scheme:
  /// ```dart
  /// headerBuilder: (token) => {
  ///   'Authorization': 'Token $token',
  /// },
  /// ```
  ///
  /// Multiple fields — token + tenant + API key:
  /// ```dart
  /// headerBuilder: (token) => {
  ///   'Authorization': 'Bearer $token',
  ///   'X-Tenant-Id': 'my-org',
  ///   'X-Api-Key': 'abc123',
  /// },
  /// ```
  ///
  /// Dynamic values read at call time:
  /// ```dart
  /// headerBuilder: (token) => {
  ///   'Authorization': 'Bearer $token',
  ///   'X-User-Id': userSession.userId,
  /// },
  /// ```
  final Map<String, String> Function(String token)? headerBuilder;

  /// Decides which hosts the token may be sent to. See
  /// [AuthConfig.sendTokenTo].
  ///
  /// `null` falls back to "same host as the client's `baseUrl`", or, when no
  /// `baseUrl` is set, every host.
  final bool Function(Uri uri)? sendTokenTo;

  /// Bounds how long a request that arrives while a refresh is already in
  /// flight will wait for that refresh to finish before giving up.
  ///
  /// Without a bound, a request whose 401 happens to be caused by
  /// [onTokenRefresh]'s own underlying call (e.g. the refresh endpoint itself
  /// returns 401 because the refresh token expired too) would wait forever —
  /// that inner call is itself queued behind the very refresh it's part of.
  final Duration refreshTimeout;

  final Dio _dio;

  bool _isRefreshing = false;
  Completer<bool>? _refreshCompleter;

  TokenRefreshInterceptor({
    required Dio dio,
    required this.getToken,
    required this.onTokenRefresh,
    this.onRefreshFailed,
    this.headerBuilder,
    this.sendTokenTo,
    this.refreshTimeout = const Duration(seconds: 30),
  }) : _dio = dio;

  /// Builds the interceptor from the [AuthConfig] held by `ApiConfig`.
  factory TokenRefreshInterceptor.fromConfig({
    required Dio dio,
    required AuthConfig config,
  }) {
    return TokenRefreshInterceptor(
      dio: dio,
      getToken: config.getToken,
      onTokenRefresh: config.onTokenRefresh,
      onRefreshFailed: config.onRefreshFailed,
      headerBuilder: config.headerBuilder,
      sendTokenTo: config.sendTokenTo,
      refreshTimeout: config.refreshTimeout,
    );
  }

  Map<String, String> _buildHeaders(String token) {
    return headerBuilder?.call(token) ?? {authorization: 'Bearer $token'};
  }

  /// Whether this request is one of ours, and so may carry the token.
  ///
  /// The client can reach any host — `ApiConfig.baseUrl` documents absolute
  /// endpoints as a supported way to hit a CDN or a third party — so without
  /// this check a session token travels to whoever the caller names. Beyond
  /// the leak, it actively breaks S3 presigned URLs, which are rejected when
  /// an `Authorization` header accompanies the presigned signature.
  bool _shouldAttach(RequestOptions options) {
    final Uri uri;
    try {
      uri = options.uri;
    } catch (_) {
      // An endpoint we cannot even resolve to a URI is not one we can confirm
      // is ours.
      return false;
    }

    final predicate = sendTokenTo;
    if (predicate != null) {
      try {
        return predicate(uri);
      } catch (_) {
        // Fail closed: a broken predicate must not leak the token.
        return false;
      }
    }

    // No baseUrl means nothing to compare against, so there is no basis to
    // withhold the token — and withholding it would break every client that
    // works purely in absolute urls.
    final baseHost = Uri.tryParse(_dio.options.baseUrl)?.host;
    if (baseHost == null || baseHost.isEmpty) return true;

    return uri.host == baseHost;
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_shouldAttach(options)) return handler.next(options);

    final token = await getToken();
    if (token != null) {
      options.headers.addAll(_buildHeaders(token));
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // A 401 from a host we never sent the token to says nothing about our
    // token. Refreshing on it wastes a round trip, and a refresh that then
    // fails would fire onRefreshFailed — logging the user out because a
    // third-party CDN rejected a request.
    if (err.response?.statusCode != 401 ||
        !_shouldAttach(err.requestOptions) ||
        _isAlreadyRetried(err.requestOptions)) {
      return handler.next(err);
    }

    // A refresh triggered by another request is already in flight — wait for
    // it instead of failing immediately, so concurrent 401s (e.g. several
    // requests firing right as the token expires) don't all error out just
    // because they lost the race to be first. Bounded by [refreshTimeout] to
    // avoid hanging forever in the pathological case described on that field.
    if (_isRefreshing) {
      final refreshed = await _refreshCompleter!.future.timeout(
        refreshTimeout,
        onTimeout: () => false,
      );
      if (refreshed) {
        return _retryRequest(err, handler);
      }
      return handler.next(err);
    }

    _isRefreshing = true;
    _refreshCompleter = Completer<bool>();

    try {
      final refreshed = await onTokenRefresh();
      _refreshCompleter!.complete(refreshed);

      if (refreshed) {
        // Awaited, not just returned. `finally` below clears _isRefreshing,
        // and an un-awaited return runs it while the replay is still in
        // flight — so a second 401 arriving in that window would see no
        // refresh in progress and start a redundant one, which is the
        // stampede this interceptor exists to prevent.
        return await _retryRequest(err, handler);
      } else {
        onRefreshFailed?.call();
        return handler.next(err);
      }
    } catch (_) {
      _refreshCompleter!.complete(false);
      onRefreshFailed?.call();
      return handler.next(err);
    } finally {
      _isRefreshing = false;
      _refreshCompleter = null;
    }
  }

  Future<void> _retryRequest(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final freshToken = await getToken();
    if (freshToken != null) {
      err.requestOptions.headers.addAll(_buildHeaders(freshToken));
    }
    err.requestOptions.extra['_tokenRetried'] = true;

    // An upload big enough to outlive its token has already had its multipart
    // body consumed by the attempt that 401'd.
    prepareForReplay(err.requestOptions);

    try {
      final response = await _dio.fetch(err.requestOptions);
      return handler.resolve(response);
    } on DioException catch (e) {
      return handler.next(e);
    }
  }

  bool _isAlreadyRetried(RequestOptions options) {
    return options.extra['_tokenRetried'] == true;
  }
}
