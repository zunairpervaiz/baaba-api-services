import 'dart:async';

import 'package:baaba_api_handler/src/utils/constants.dart';
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
    this.refreshTimeout = const Duration(seconds: 30),
  }) : _dio = dio;

  Map<String, String> _buildHeaders(String token) {
    return headerBuilder?.call(token) ?? {authorization: 'Bearer $token'};
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
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
    if (err.response?.statusCode != 401 || _isAlreadyRetried(err.requestOptions)) {
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
        return _retryRequest(err, handler);
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
