import 'dart:async';

import 'package:baaba_api_handler/src/config/auth_config.dart';
import 'package:baaba_api_handler/src/utils/constants.dart';
import 'package:baaba_api_handler/src/utils/refresh_zone.dart';
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
/// Use `ApiServices.init(ApiConfig(auth: AuthConfig(...)))` to set this up — you do not need to instantiate
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

  /// Bumped by every successful refresh. Each request records the value it
  /// was sent under, so a `401` can tell — synchronously — that a refresh has
  /// already happened since.
  int _generation = 0;
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

    // Read before the await. A refresh can finish while getToken() is
    // running, and a request that read the old token but recorded the new
    // generation would look current — its 401 would start a redundant
    // refresh. Recorded early, it is at worst replayed once.
    final generation = _generation;
    final token = await getToken();
    if (token != null) {
      options.headers.addAll(_buildHeaders(token));
    }
    // Remembered so a 401 can tell whether it is about the current token or
    // one that has been replaced since. Updated on every attempt, since a
    // retry or replay passes back through here. A hash, not the token: extra
    // is printed by the logger and handed to observers, and only equality is
    // needed. A collision just means refreshing, as before.
    options.extra[_sentTokenKey] = token?.hashCode;
    options.extra[_generationKey] = generation;
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
    //
    // A 401 on a request made *by* onTokenRefresh is the refresh failing — an
    // expired refresh token. It must neither start a refresh nor wait for one:
    // the refresh it would wait on is its own, so it sat out the whole
    // refreshTimeout, loader up, before the user was signed out.
    if (err.response?.statusCode != 401 ||
        isInsideTokenRefresh ||
        !_shouldAttach(err.requestOptions) ||
        _isAlreadyRetried(err.requestOptions)) {
      return handler.next(err);
    }

    // A 401 that arrives after another request's refresh has already
    // finished — sent with the old token, answered late. The token it
    // complains about is gone, so replay with the current one instead of
    // refreshing again: against a backend that rotates refresh tokens, a
    // redundant refresh can fail outright and sign the user out.
    //
    // The generation check comes first because it is synchronous: nothing
    // can slip in between reading it and acting on it.
    //
    // Unless a refresh is running right now: then the current token is the
    // one being replaced, and replaying with it would 401 again and fail for
    // good, since a request is replayed only once. It waits for that refresh
    // below instead, like any other 401 arriving mid-refresh.
    final sentUnder = err.requestOptions.extra[_generationKey];
    if (sentUnder is int && sentUnder != _generation && !_isRefreshing) {
      return _retryRequest(err, handler);
    }

    // The token check covers a token replaced outside this interceptor — a
    // proactive refresh, a fresh login. It must stay before _isRefreshing,
    // never after: getToken() is awaited, and the test-and-set of
    // _isRefreshing below must stay synchronous or two 401s could both pass
    // it and refresh twice.
    final sentWith = err.requestOptions.extra[_sentTokenKey];
    if (sentWith != null && !_isRefreshing) {
      final current = await _currentToken();
      if (current != null && current.hashCode != sentWith) {
        return _retryRequest(err, handler);
      }
    }

    // A refresh triggered by another request is already in flight — wait for
    // it instead of failing immediately, so concurrent 401s (e.g. several
    // requests firing right as the token expires) don't all error out just
    // because they lost the race to be first. Bounded by [refreshTimeout] so
    // an onTokenRefresh that never completes cannot hang them forever.
    //
    // The refresh may already have finished, with its originator still
    // replaying under the guard. A 401 sent with the *new* token in that
    // window replays once rather than refreshing again — deliberately: a
    // token rejected moments after it was issued is more likely propagation
    // lag than expiry, and against a backend that rotates refresh tokens a
    // second refresh can sign the user out.
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
    final completer = _refreshCompleter = Completer<bool>();

    try {
      // Only the refresh itself may count as a failed refresh. A replay that
      // threw after a *successful* one used to land in a catch around both,
      // which completed the completer a second time — so the request failed
      // with "Future already completed" in place of the real error — and
      // which would then have fired onRefreshFailed, signing out a user
      // whose session had just been renewed.
      final refreshed = await _refresh();
      if (refreshed) _generation++;
      completer.complete(refreshed);

      if (!refreshed) {
        // Guarded: it is usually logout navigation, which can throw, and the
        // caller must still see the 401 rather than that exception — code
        // checking `errorType == ErrorSource.unauthorized` depends on it.
        try {
          onRefreshFailed?.call();
        } catch (_) {}
        return handler.next(err);
      }

      // Awaited, not just returned. `finally` below clears _isRefreshing,
      // and an un-awaited return runs it while the replay is still in
      // flight — so a second 401 arriving in that window would see no
      // refresh in progress and start a redundant one, which is the
      // stampede this interceptor exists to prevent.
      return await _retryRequest(err, handler);
    } finally {
      _isRefreshing = false;
      _refreshCompleter = null;
    }
  }

  /// The token as it stands now, or `null` if it cannot be read — in which
  /// case the 401 is handled by refreshing, as it always was.
  Future<String?> _currentToken() async {
    try {
      return await getToken();
    } catch (_) {
      return null;
    }
  }

  /// Runs [onTokenRefresh], treating a throw as a failed refresh.
  ///
  /// A plain try/catch rather than `.catchError((_) => false)`: an
  /// `() async => throw ...` callback has the runtime type `Future<Never>`,
  /// and `catchError` on that rejects a `false` with a `TypeError`.
  Future<bool> _refresh() async {
    try {
      // Marked, so a refresh request made through the same client is not
      // queued behind the requests waiting on it. See refresh_zone.dart.
      return await runAsTokenRefresh(onTokenRefresh);
    } catch (_) {
      return false;
    }
  }

  /// Replays the request with the fresh token. Never throws: whatever goes
  /// wrong, the original request still gets an answer through [handler].
  Future<void> _retryRequest(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // The refresh itself still happened and helps every later request; only
    // this one, whose stream body is spent, cannot be sent again.
    if (!canReplay(err.requestOptions)) return handler.next(err);
    try {
      final freshToken = await getToken();
      if (freshToken != null) {
        err.requestOptions.headers.addAll(_buildHeaders(freshToken));
      }
      err.requestOptions.extra['_tokenRetried'] = true;

      // An upload big enough to outlive its token has already had its
      // multipart body consumed by the attempt that 401'd.
      prepareForReplay(err.requestOptions);

      final response = await _dio.fetch(err.requestOptions);
      return handler.resolve(response);
    } on DioException catch (e) {
      return handler.next(e);
    } catch (e, stackTrace) {
      return handler.next(
        DioException(
          requestOptions: err.requestOptions,
          error: e,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  static const String _sentTokenKey = '_tokenSent';
  static const String _generationKey = '_tokenGeneration';

  bool _isAlreadyRetried(RequestOptions options) {
    return options.extra['_tokenRetried'] == true;
  }
}
