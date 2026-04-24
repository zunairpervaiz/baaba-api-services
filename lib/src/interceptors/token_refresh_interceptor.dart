import 'dart:async';

import 'package:baaba_api_handler/src/utils/constants.dart';
import 'package:dio/dio.dart';

/// A Dio interceptor that automatically attaches auth headers to every request
/// and retries requests that receive a 401 by refreshing the token first.
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
  final Dio _dio;

  bool _isRefreshing = false;
  Completer<bool>? _refreshCompleter;

  TokenRefreshInterceptor({
    required Dio dio,
    required this.getToken,
    required this.onTokenRefresh,
    this.onRefreshFailed,
    this.headerBuilder,
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

    // If a refresh is already in progress (e.g. the refresh endpoint itself returned 401),
    // fail immediately to avoid a deadlock where both sides await each other.
    if (_isRefreshing) {
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
