import 'dart:async';

import 'package:baaba_api_handler/src/config/auth_config.dart';
import 'package:baaba_api_handler/src/config/refresh_outcome.dart';
import 'package:baaba_api_handler/src/utils/token_headers.dart';
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
  /// successfully refreshed, `false` otherwise. See
  /// [AuthConfig.onTokenRefresh].
  final Future<bool> Function()? onTokenRefresh;

  /// Performs the token refresh, reporting why it failed. See
  /// [AuthConfig.refreshSession]. Exactly one of this and [onTokenRefresh] is
  /// set.
  final Future<RefreshOutcome> Function()? refreshSession;

  /// Called when the session is over (e.g. the refresh endpoint returns 401).
  /// Use this to trigger a logout.
  final void Function()? onRefreshFailed;

  /// Asked before a request that carries the token; `true` refreshes first.
  /// See [AuthConfig.isTokenExpired].
  final FutureOr<bool> Function()? isTokenExpired;

  /// Requests whose `401` must not trigger a refresh. See
  /// [AuthConfig.skipRefresh].
  final bool Function(RequestOptions options)? skipRefresh;

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
  Completer<RefreshOutcome>? _refreshCompleter;

  TokenRefreshInterceptor({
    required Dio dio,
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
       ),
       _dio = dio;

  /// Builds the interceptor from the [AuthConfig] held by `ApiConfig`.
  factory TokenRefreshInterceptor.fromConfig({
    required Dio dio,
    required AuthConfig config,
  }) {
    return TokenRefreshInterceptor(
      dio: dio,
      getToken: config.getToken,
      onTokenRefresh: config.onTokenRefresh,
      refreshSession: config.refreshSession,
      onRefreshFailed: config.onRefreshFailed,
      isTokenExpired: config.isTokenExpired,
      skipRefresh: config.skipRefresh,
      headerBuilder: config.headerBuilder,
      sendTokenTo: config.sendTokenTo,
      refreshTimeout: config.refreshTimeout,
    );
  }

  Map<String, String> _buildHeaders(String token) {
    return headerBuilder?.call(token) ?? {authorization: 'Bearer $token'};
  }

  /// Puts [token] on [options], recording which headers carry it so the
  /// transport can drop them on a redirect to another origin.
  void _attach(RequestOptions options, String token) {
    final headers = _buildHeaders(token);
    options.headers.addAll(headers);
    options.extra[tokenHeadersKey] = [
      for (final name in headers.keys) name.toLowerCase(),
    ];
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
    return _isOurs(uri);
  }

  /// Whether the 401 in [err] came from one of our hosts.
  ///
  /// A redirect is followed inside one Dio call, so a request to our API can
  /// be answered by whatever host it was redirected to — a CDN serving an
  /// expired signed url, say, which never saw our token (it is dropped on a
  /// cross-origin hop). Its 401 says nothing about our session.
  bool _answeredByUs(DioException err) {
    final redirects = err.response?.redirects;
    if (redirects == null || redirects.isEmpty) return true;
    // HttpClient records each Location as written, unresolved, and a
    // relative one is relative to the hop before it — not to the request.
    // Resolving only the last against the original url made a CDN's
    // `302 /expired` look like our own host.
    Uri answered;
    try {
      answered = err.requestOptions.uri;
      for (final redirect in redirects) {
        answered = answered.resolveUri(redirect.location);
      }
    } catch (_) {
      return false;
    }
    return _isOurs(answered);
  }

  bool _isOurs(Uri uri) {
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

  /// Whether [AuthConfig.skipRefresh] exempts this request. A throwing
  /// predicate exempts nothing, so auth keeps working as it did without one.
  bool _isExempt(RequestOptions options) {
    final predicate = skipRefresh;
    if (predicate == null) return false;
    try {
      return predicate(options);
    } catch (_) {
      return false;
    }
  }

  /// Whether the token should be renewed before this request goes out.
  Future<bool> _needsProactiveRefresh(RequestOptions options) async {
    final check = isTokenExpired;
    // Inside the refresh, the refresh request itself would wait on the very
    // refresh it belongs to.
    if (check == null || isInsideTokenRefresh || _isExempt(options)) {
      return false;
    }
    try {
      return await check();
    } catch (_) {
      // The server's 401 is the backstop.
      return false;
    }
  }

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!_shouldAttach(options)) return handler.next(options);

    if (await _needsProactiveRefresh(options)) {
      final outcome = await _sharedRefresh();
      if (outcome == RefreshOutcome.sessionExpired) {
        // Sending it would only earn the 401 the refresh just predicted, and
        // a second refresh attempt for it would fire onRefreshFailed twice.
        // Rejected as that 401, so the caller sees ErrorSource.unauthorized.
        return handler.reject(_sessionExpired(options));
      }
      // RefreshOutcome.failed: send with the token we have and let the server
      // decide, rather than failing a request that may well succeed. Marked,
      // so its 401 does not try the refresh that just failed a second time.
      if (outcome == RefreshOutcome.failed) {
        options.extra[_refreshFailedKey] = true;
      }
    }

    // Read before the await. A refresh can finish while getToken() is
    // running, and a request that read the old token but recorded the new
    // generation would look current — its 401 would start a redundant
    // refresh. Recorded early, it is at worst replayed once.
    final generation = _generation;
    final token = await getToken();
    if (token != null) _attach(options, token);
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
    // A 401 from a host we never sent the token to — directly, or at the end
    // of a redirect — says nothing about our token. Refreshing on it wastes a round trip, and a refresh that then
    // fails would fire onRefreshFailed — logging the user out because a
    // third-party CDN rejected a request.
    //
    // A 401 on a request made *by* onTokenRefresh is the refresh failing — an
    // expired refresh token. It must neither start a refresh nor wait for one:
    // the refresh it would wait on is its own, so it sat out the whole
    // refreshTimeout, loader up, before the user was signed out.
    //
    // A 401 from a request skipRefresh names — login, logout — is an answer
    // about the request, not about the session.
    if (err.response?.statusCode != 401 ||
        isInsideTokenRefresh ||
        !_shouldAttach(err.requestOptions) ||
        !_answeredByUs(err) ||
        _isExempt(err.requestOptions) ||
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
      // A whole refresh can start and finish during that await, after
      // getToken() had already read the old token. Without a second look at
      // the generation this 401 would start a redundant refresh.
      if (sentUnder is int && sentUnder != _generation && !_isRefreshing) {
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
      if (await _awaitRunningRefresh() == RefreshOutcome.refreshed) {
        return _retryRequest(err, handler);
      }
      return handler.next(err);
    }

    // Its proactive refresh already failed on the way out. Trying again at
    // once doubles the refresh traffic of every request while offline, and
    // against a backend that rotates refresh tokens a retry after a timeout
    // the server did act on can sign the user out.
    if (err.requestOptions.extra[_refreshFailedKey] == true) {
      return handler.next(err);
    }

    try {
      if (await _startRefresh() != RefreshOutcome.refreshed) {
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

  /// Joins the refresh in flight, or starts one. For the proactive path,
  /// which — unlike a 401 — has no replay to hold the guard for.
  Future<RefreshOutcome> _sharedRefresh() async {
    if (_isRefreshing) return _awaitRunningRefresh();
    try {
      return await _startRefresh();
    } finally {
      _isRefreshing = false;
      _refreshCompleter = null;
    }
  }

  /// Waits for the refresh another request started. Bounded by
  /// [refreshTimeout], so a refresh that never completes cannot hang every
  /// request behind it; running out counts as [RefreshOutcome.failed], which
  /// does not end the session.
  Future<RefreshOutcome> _awaitRunningRefresh() => _refreshCompleter!.future
      .timeout(refreshTimeout, onTimeout: () => RefreshOutcome.failed);

  /// Starts the refresh, publishing its outcome to every request waiting on
  /// it, and fires [onRefreshFailed] when the session is over.
  ///
  /// Must be called synchronously after seeing `_isRefreshing` false, so two
  /// callers cannot both start one. Does not clear the guard: the caller does,
  /// in a `finally`, once it is done with whatever must happen under it.
  Future<RefreshOutcome> _startRefresh() async {
    _isRefreshing = true;
    final completer = _refreshCompleter = Completer<RefreshOutcome>();

    // Only the refresh itself may count as a failed refresh. A replay that
    // threw after a *successful* one used to land in a catch around both,
    // which completed the completer a second time — so the request failed
    // with "Future already completed" in place of the real error — and which
    // would then have fired onRefreshFailed, signing out a user whose session
    // had just been renewed.
    final outcome = await _refresh();
    if (outcome == RefreshOutcome.refreshed) _generation++;
    completer.complete(outcome);

    if (outcome == RefreshOutcome.sessionExpired) {
      // Guarded: it is usually logout navigation, which can throw, and the
      // caller must still see the 401 rather than that exception — code
      // checking `errorType == ErrorSource.unauthorized` depends on it.
      try {
        onRefreshFailed?.call();
      } catch (_) {}
    }
    return outcome;
  }

  /// Runs the configured refresh callback.
  ///
  /// A throw from [onTokenRefresh] ends the session, as it always has; a
  /// throw from [refreshSession] does not, since that callback has
  /// [RefreshOutcome.sessionExpired] to say so explicitly.
  ///
  /// A plain try/catch rather than `.catchError(...)`: an
  /// `() async => throw ...` callback has the runtime type `Future<Never>`,
  /// and `catchError` on that rejects a fallback value with a `TypeError`.
  Future<RefreshOutcome> _refresh() async {
    final withOutcome = refreshSession;
    try {
      // Marked, so a refresh request made through the same client is not
      // queued behind the requests waiting on it. See refresh_zone.dart.
      if (withOutcome != null) return await runAsTokenRefresh(withOutcome);
      // Neither callback: AuthConfig asserts against it, but asserts are gone
      // in release. Without this the `!` threw, which reads as the session
      // ending — every 401 fired onRefreshFailed and signed the user out.
      final plain = onTokenRefresh;
      if (plain == null) return RefreshOutcome.failed;
      final refreshed = await runAsTokenRefresh(plain);
      return refreshed
          ? RefreshOutcome.refreshed
          : RefreshOutcome.sessionExpired;
    } catch (_) {
      return withOutcome != null
          ? RefreshOutcome.failed
          : RefreshOutcome.sessionExpired;
    }
  }

  /// The `401` a request would have earned, for one rejected before sending
  /// because the proactive refresh found the session over.
  static DioException _sessionExpired(RequestOptions options) {
    return DioException.badResponse(
      statusCode: 401,
      requestOptions: options,
      response: Response<dynamic>(requestOptions: options, statusCode: 401),
    );
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
      if (freshToken != null) _attach(err.requestOptions, freshToken);
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
  static const String _refreshFailedKey = '_tokenRefreshFailed';

  bool _isAlreadyRetried(RequestOptions options) {
    return options.extra['_tokenRetried'] == true;
  }
}
