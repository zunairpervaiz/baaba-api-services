import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:baaba_api_handler/src/api_cache_helper.dart';
import 'package:baaba_api_handler/src/config/api_config.dart';
import 'package:baaba_api_handler/src/config/cache_policy.dart';
import 'package:baaba_api_handler/src/dio_factory.dart';
import 'package:baaba_api_handler/src/utils/cache_key.dart';
import 'package:baaba_api_handler/src/utils/constants.dart';
import 'package:baaba_api_handler/src/utils/error_handler.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/http_methods.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:baaba_api_handler/src/utils/success_check.dart';
import 'package:baaba_api_handler/src/utils/refresh_zone.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/src/utils/response_strings.dart';
import 'package:baaba_api_handler/src/utils/upload_file.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';

/// Turns a single-object parser into one that reads a JSON array, for the
/// common list endpoint.
///
/// ```dart
/// // [{"id": 1}, {"id": 2}]
/// final users = await api.getAs<List<User>>(
///   endpoint: '/users',
///   parser: listParser(User.fromJson),
/// );
///
/// // {"data": [{"id": 1}], "meta": {...}} — pull the array out of a wrapper
/// final users = await api.getAs<List<User>>(
///   endpoint: '/users',
///   parser: listParser(User.fromJson, key: 'data'),
/// );
/// ```
///
/// Throws if the body is not a list (or [key] is missing), which the `*As<T>`
/// methods turn into a `Failure` with `ErrorSource.parseError` rather than
/// letting it escape.
List<T> Function(dynamic data) listParser<T>(
  T Function(Map<String, dynamic> json) fromJson, {
  String? key,
}) {
  return (dynamic data) {
    final raw = key == null ? data : (data as Map)[key];
    return (raw as List)
        .map((item) => fromJson(Map<String, dynamic>.from(item as Map)))
        .toList();
  };
}

/// A typed HTTP client wrapping Dio. All methods return `Either<Failure, Response>` —
/// use `.fold(onLeft, onRight)` to handle errors and successes without exceptions.
///
/// ---
///
/// ## Setup
///
/// Call [init] once at app startup, before any request:
///
/// ```dart
/// void main() {
///   ApiServices.init(ApiConfig(
///     baseUrl: 'https://api.example.com',
///     auth: AuthConfig(
///       getToken: () => storage.read(key: 'access_token'),
///       onTokenRefresh: () => authRepository.refresh(),
///       onRefreshFailed: () => Get.offAllNamed(Routes.login),
///     ),
///   ));
///   runApp(const MyApp());
/// }
/// ```
///
/// Everything in [ApiConfig] is optional, so `ApiServices.init(const ApiConfig())`
/// gives a plain client with sane timeouts and no auth. Skipping [init]
/// entirely also works — [instance] builds a default client on first use.
///
/// ---
///
/// ## Making requests
///
/// ```dart
/// final result = await ApiServices.instance().get(endpoint: '/users');
///
/// result.fold(
///   (failure) => print(failure.message),
///   (response) => print(response.data),
/// );
/// ```
///
/// Or skip the manual deserialization with the `*As<T>` variants:
///
/// ```dart
/// final result = await ApiServices.instance().getAs<User>(
///   endpoint: '/users/1',
///   parser: User.fromJson,
/// );
///
/// result.fold(
///   (failure) => emit(ErrorState(failure.message)),
///   (user) => emit(LoadedState(user)),
/// );
/// ```
abstract interface class ApiServices {
  static ApiServices? _instance;
  static ApiConfig _config = const ApiConfig();
  static void Function()? _onLoadingShow;
  static void Function()? _onLoadingHide;

  /// Requests currently holding the loader.
  ///
  /// Static, matching the scope of the callbacks it drives: the indicator is
  /// one global widget. Counting per instance would let a second `init()` —
  /// re-configuring after a login, say — start a fresh count while requests
  /// from the previous client are still in flight and still driving the same
  /// dialog.
  static int _activeLoadingCount = 0;

  /// Bumped by [reset], so a request that was already holding the loader
  /// when the count was zeroed does not decrement the fresh count when it
  /// finishes. Without it the count went negative, and the next request's
  /// increment landed on zero — so the loader never showed again.
  static int _loaderEpoch = 0;

  /// The configuration currently in effect. Read-only — call [init] to change
  /// it.
  static ApiConfig get config => _config;

  /// Configures the client and builds the singleton.
  ///
  /// Call once at app startup, before any request. Calling it again replaces
  /// the singleton, which is what you want after a logout/re-login.
  ///
  /// Settings read at *request* time — `bypassConnectivityCheck`, `isSuccess`
  /// — take effect immediately. Settings baked into the Dio client and its
  /// interceptors — `baseUrl`, timeouts, `logging`, `retry`, `auth`,
  /// `observer`, `httpClientAdapter` — apply to the client built here, so
  /// changing them means calling [init] again.
  ///
  /// See [ApiConfig] for every option.
  static void init(ApiConfig config) {
    _config = config;
    _instance = ApiServicesImplementation.instanceFor(
      dio: DioFactory().getDio(config: config),
      networkInfo: NetworkInfo(
        cacheTtl: config.connectivityCacheTtl,
        probe: config.connectivityProbe,
      ),
    );
  }

  /// Returns the singleton instance, building a default one on first use if
  /// [init] was never called.
  ///
  /// > **Call [init] before anything captures this.** A caller that holds on
  /// > to the returned object — a repository registered as a DI singleton, for
  /// > instance — keeps the client it was given. Reach for it before [init]
  /// > runs and that client has no `baseUrl` and no auth, and a later [init]
  /// > will not reach it. The symptom is requests going out unauthenticated
  /// > against a relative path. Either configure in `main()` before wiring up
  /// > dependencies, or resolve `ApiServices.instance()` per call rather than
  /// > storing it.
  ///
  /// Pass a custom [dio] only in tests — do not use in production code. It is
  /// ignored once an instance exists; call [reset] first if you need to
  /// replace one.
  static ApiServices instance([Dio? dio]) {
    _instance ??= ApiServicesImplementation.instanceFor(
      dio: dio ?? DioFactory().getDio(config: _config),
      networkInfo: NetworkInfo(
        cacheTtl: _config.connectivityCacheTtl,
        probe: _config.connectivityProbe,
      ),
    );
    return _instance!;
  }

  /// Discards the singleton, the configuration, and the loader callbacks.
  ///
  /// Two things this fixes. In tests, state set by one test no longer leaks
  /// into the next — call it in `tearDown`. In an app, it gives you a clean
  /// slate on logout, so the next user does not inherit the previous one's
  /// client.
  ///
  /// The next [instance] call builds a fresh default client.
  ///
  /// Requests still in flight on the discarded client are cancelled, and
  /// complete with `ErrorSource.cancel`. Left running, one that finished
  /// after a logout's `clearAllCache()` would write the previous user's
  /// response straight back into the cache — and its token would still be
  /// the previous user's. [init] does not do this, since re-configuring is
  /// not necessarily a change of user.
  static void reset() {
    final previous = _instance;
    if (previous is ApiServicesImplementation) previous._close();
    _instance = null;
    _config = const ApiConfig();
    _onLoadingShow = null;
    _onLoadingHide = null;
    _activeLoadingCount = 0;
    _loaderEpoch++;
  }

  /// Configures a global loading indicator shown automatically around every
  /// request, so callers don't need to manage an `isLoading` flag per screen.
  ///
  /// [onShow] and [onHide] are plain callbacks — this package has no opinion
  /// on how the indicator is presented. Wire them to whatever your app uses:
  ///
  /// ```dart
  /// // GetX
  /// ApiServices.configureLoader(
  ///   onShow: () => Get.dialog(const LoadingDialog(), barrierDismissible: false),
  ///   onHide: () => Get.back(),
  /// );
  ///
  /// // Navigator with a global key
  /// ApiServices.configureLoader(
  ///   onShow: () => showDialog(
  ///     context: navigatorKey.currentContext!,
  ///     barrierDismissible: false,
  ///     builder: (_) => const LoadingDialog(),
  ///   ),
  ///   onHide: () => navigatorKey.currentState!.pop(),
  /// );
  /// ```
  ///
  /// Concurrent requests share one indicator: [onShow] fires only when the
  /// first request starts, [onHide] only once every in-flight request
  /// (success, failure, or exception) has finished. Pass `showLoader: false`
  /// to an individual request to opt it out (e.g. background polling).
  static void configureLoader({
    required void Function() onShow,
    required void Function() onHide,
  }) {
    _onLoadingShow = onShow;
    _onLoadingHide = onHide;
  }

  /// Sends a GET request to [endpoint].
  ///
  /// Use for fetching resources that don't require a request body. Query
  /// parameters go in [params].
  ///
  /// Returns `Right(Response)` on success, `Left(Failure)` on any error
  /// (network, timeout, 4xx/5xx, no internet).
  ///
  /// **Example:**
  ///
  /// ```dart
  /// final result = await _api.get(
  ///   endpoint: '/users',
  ///   params: {'page': 1, 'limit': 20},
  /// );
  ///
  /// result.fold(
  ///   (failure) => emit(ErrorState(failure.message)),
  ///   (response) => emit(LoadedState(UserListModel.fromJson(response.data))),
  /// );
  /// ```
  ///
  /// **Caching.** Omit [cachePolicy] and the project-wide
  /// `ApiConfig.defaultCachePolicy` applies — itself [CachePolicy.networkOnly]
  /// unless changed, which ignores the cache entirely. Anything else stores
  /// successful responses and can serve them back; see [CachePolicy].
  /// [cacheMaxAge] bounds how old a cached entry may be before it counts as a
  /// miss.
  ///
  /// A project can forbid caching outright with
  /// `ApiConfig(cacheEnabled: false)`, which overrides whatever is passed
  /// here.
  ///
  /// **De-duplication.** Two identical GETs in flight at the same time share
  /// one network call by default. Pass `dedupe: false` to force a separate
  /// request. Automatically skipped when you supply your own [cancelToken],
  /// since cancelling one caller must not cancel the other.
  Future<Either<Failure, Response>> get({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
    CachePolicy? cachePolicy,
    Duration? cacheMaxAge,
    bool dedupe = true,
  });

  /// [get], with the response body deserialized into [T].
  ///
  /// [parser] receives `response.data` — already-decoded JSON, so usually a
  /// `Map<String, dynamic>` or a `List`. If it throws, the result is a
  /// `Failure` with `ErrorSource.parseError` carrying the raw body in
  /// `failure.data`; the exception never reaches the caller.
  ///
  /// ```dart
  /// final user = await _api.getAs<User>(
  ///   endpoint: '/users/1',
  ///   parser: User.fromJson,
  /// );
  ///
  /// final users = await _api.getAs<List<User>>(
  ///   endpoint: '/users',
  ///   parser: listParser(User.fromJson),
  /// );
  /// ```
  Future<Either<Failure, T>> getAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
    CachePolicy? cachePolicy,
    Duration? cacheMaxAge,
    bool dedupe = true,
  });

  /// Sends a POST request to [endpoint].
  ///
  /// Use for creating resources or submitting forms. Pass the request body
  /// as [data] (a `Map`, a model's `.toJson()`, or `FormData` for file uploads
  /// — though [upload] is easier for that).
  ///
  /// **Example:**
  ///
  /// ```dart
  /// final result = await _api.post(
  ///   endpoint: '/auth/login',
  ///   data: {'email': email, 'password': password},
  /// );
  /// ```
  ///
  /// Never auto-retried on a timeout: the server may already have processed
  /// it, and repeating it could create the same record twice.
  Future<Either<Failure, Response>> post({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  });

  /// [post], with the response body deserialized into [T]. See [getAs].
  Future<Either<Failure, T>> postAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  });

  /// Sends a PUT request to [endpoint].
  ///
  /// Use for full replacement of a resource. The request body in [data] should
  /// contain the complete updated representation.
  ///
  /// **Example:**
  ///
  /// ```dart
  /// final result = await _api.put(
  ///   endpoint: '/users/42',
  ///   data: updatedUser.toJson(),
  /// );
  /// ```
  Future<Either<Failure, Response>> put({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  });

  /// [put], with the response body deserialized into [T]. See [getAs].
  Future<Either<Failure, T>> putAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  });

  /// Sends a DELETE request to [endpoint].
  ///
  /// Use for removing a resource. Some APIs accept a body with delete requests;
  /// pass it via [data] if needed.
  ///
  /// **Example:**
  ///
  /// ```dart
  /// final result = await _api.delete(endpoint: '/users/42');
  ///
  /// result.fold(
  ///   (failure) => showError(failure.message),
  ///   (_) => showSuccess('User deleted'),
  /// );
  /// ```
  Future<Either<Failure, Response>> delete({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  });

  /// [delete], with the response body deserialized into [T]. See [getAs].
  Future<Either<Failure, T>> deleteAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  });

  /// Sends a PATCH request to [endpoint].
  ///
  /// Use for partial updates — only send the fields that changed in [data].
  ///
  /// **Example:**
  ///
  /// ```dart
  /// final result = await _api.patch(
  ///   endpoint: '/users/42',
  ///   data: {'displayName': newName},
  /// );
  /// ```
  Future<Either<Failure, Response>> patch({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  });

  /// [patch], with the response body deserialized into [T]. See [getAs].
  Future<Either<Failure, T>> patchAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  });

  /// Sends a HEAD request to [endpoint].
  ///
  /// Identical to [get] except that the server returns headers only and no
  /// body — use it to check whether a resource exists, read its
  /// `Content-Length` before committing to a download, or test a
  /// `Last-Modified` without paying for the payload.
  ///
  /// ```dart
  /// final result = await _api.head(endpoint: '/files/report.pdf');
  /// final size = result.fold(
  ///   (_) => null,
  ///   (response) => response.headers.value('content-length'),
  /// );
  /// ```
  ///
  /// Idempotent, so transient failures are retried like a [get]. Takes no
  /// `responseType`: there is no body for one to apply to.
  Future<Either<Failure, Response>> head({
    required String endpoint,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    String? tag,
    bool showLoader = true,
    bool dedupe = true,
  });

  /// Sends an OPTIONS request to [endpoint].
  ///
  /// Asks the server which methods and CORS rules apply to a resource. Rarely
  /// needed from app code — browsers issue their own preflights — but useful
  /// for capability discovery against an API that advertises itself this way.
  ///
  /// Idempotent, so transient failures are retried like a [get].
  Future<Either<Failure, Response>> options({
    required String endpoint,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
    bool dedupe = true,
  });

  /// Uploads files as a multipart request, alongside any ordinary form
  /// [fields].
  ///
  /// Saves hand-building `FormData` and gets the platform detail right:
  /// [UploadFile.fromPath] on mobile and desktop, [UploadFile.fromBytes] on
  /// web, where a picked file has no filesystem path.
  ///
  /// ```dart
  /// final result = await _api.upload(
  ///   endpoint: '/profile/avatar',
  ///   fields: {'userId': '42'},
  ///   files: [UploadFile.fromPath(field: 'avatar', path: picked.path)],
  ///   onSendProgress: (sent, total) => progress.value = sent / total,
  /// );
  /// ```
  ///
  /// Defaults to `POST`; pass [method] for an API that expects `PUT` or
  /// `PATCH`.
  ///
  /// A timeout is never retried, since the server may already have stored the
  /// file. A `429` or `503` is, because the server said it did not process the
  /// request — as is a replay after a `401` refresh, which matters for an
  /// upload long enough to outlive its token. In both cases the multipart body
  /// is rebuilt first: it is a stream, and sending the consumed one would
  /// throw.
  Future<Either<Failure, Response>> upload({
    required String endpoint,
    Map<String, dynamic> fields = const {},
    List<UploadFile> files = const [],
    HttpMethod method = HttpMethod.post,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  });

  /// Downloads the file at [endpoint] and streams it directly to [savePath],
  /// instead of loading the whole response into memory like [get] would.
  ///
  /// Use for images, PDFs, exports, or any file response.
  ///
  /// **Example:**
  ///
  /// ```dart
  /// final dir = await getApplicationDocumentsDirectory();
  /// final result = await _api.download(
  ///   endpoint: '/files/report.pdf',
  ///   savePath: '${dir.path}/report.pdf',
  ///   onReceiveProgress: (received, total) => print('${received / total * 100}%'),
  /// );
  ///
  /// result.fold(
  ///   (failure) => showError(failure.message),
  ///   (_) => openFile(savePath),
  /// );
  /// ```
  Future<Either<Failure, Response>> download({
    required String endpoint,
    required String savePath,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    String? tag,
    bool deleteOnError = true,
    bool showLoader = true,
  });

  /// Cancels in-flight requests — every one of them, or just those made under
  /// a [tag].
  ///
  /// Call this when leaving a screen to abort any pending requests that are
  /// no longer needed (e.g. in `onClose` / `dispose`).
  ///
  /// **Cancel everything** (omit [tag]):
  ///
  /// ```dart
  /// @override
  /// void onClose() {
  ///   _api.cancelRequest(cancellationReason: 'Screen closed');
  ///   super.onClose();
  /// }
  /// ```
  ///
  /// **Cancel one screen's requests.** Without [tag] this is all-or-nothing,
  /// so a screen tearing down would abort requests belonging to screens still
  /// on the stack. Pass the same tag to the requests and to the cancel:
  ///
  /// ```dart
  /// await _api.get(endpoint: '/feed', tag: 'feed');
  /// await _api.get(endpoint: '/stories', tag: 'feed');
  ///
  /// _api.cancelRequest(tag: 'feed', cancellationReason: 'Left the feed');
  /// ```
  ///
  /// Untagged requests are cancelled only by a call that omits [tag].
  void cancelRequest({String? tag, String cancellationReason = ''});
}

class ApiServicesImplementation implements ApiServices {
  final Dio _dio;
  final NetworkInfo _networkInfo;
  final ApiCacheHelper? _cacheOverride;

  final Map<String, String> _defaultHeader = {
    contentType: applicationJson,
    accept: applicationJson,
  };

  // Tracks every active CancelToken, against the tags of the requests using
  // it (null for one made without a tag), so cancelRequest() can cancel
  // either everything or just one screen's worth.
  //
  // A list, one entry per request, because a caller may share one token
  // across several requests. Keyed one-to-one, the first of them to finish
  // unregistered the token for all the rest, and cancelRequest() could no
  // longer reach them.
  final Map<CancelToken, List<String?>> _activeTokens = {};

  // Set by ApiServices.reset(): a discarded client sends nothing further.
  bool _closed = false;

  // Identical GETs in flight at the same time share one network call.
  final Map<String, Future<Either<Failure, Response>>> _inFlight = {};

  // Caps how many requests actually reach the network at once.
  final _RequestGate _gate;

  ApiServicesImplementation._({
    required Dio dio,
    NetworkInfo? networkInfo,
    ApiCacheHelper? cacheHelper,
  })  : _dio = dio,
        _networkInfo = networkInfo ?? NetworkInfo(),
        _cacheOverride = cacheHelper,
        _gate = _RequestGate(ApiServices._config.maxConcurrentRequests);

  factory ApiServicesImplementation.instanceFor({
    required Dio dio,
    NetworkInfo? networkInfo,
    ApiCacheHelper? cacheHelper,
  }) {
    return ApiServicesImplementation._(
      dio: dio,
      networkInfo: networkInfo,
      cacheHelper: cacheHelper,
    );
  }

  /// Resolved lazily: touching [ApiCacheHelper.instance] opens the SQLite
  /// database, which must not happen for callers that never use a cache
  /// policy.
  ApiCacheHelper get _cache => _cacheOverride ?? ApiCacheHelper.instance;

  // ---------------------------------------------------------------------------
  // Request pipeline
  // ---------------------------------------------------------------------------

  /// Outermost layer: loader accounting and cache policy.
  Future<Either<Failure, Response>> _sendRequest(
    _Call call, {
    bool showLoader = true,
  }) async {
    final epoch = showLoader ? _showLoader() : null;
    try {
      // Reported here, at the one layer that runs once per caller. Deeper
      // layers are shared: de-duplication collapses two callers onto one
      // _performRequest, so notifying from there would emit a single event
      // for two calls.
      return _notify(await _resolve(call));
    } finally {
      if (epoch != null) _hideLoader(epoch);
    }
  }

  /// Applies the cache policy around the network call.
  Future<Either<Failure, Response>> _resolve(_Call call) async {
    final policy = _effectiveCachePolicy(call);

    final cacheKey =
        policy == CachePolicy.networkOnly ? null : _cacheKeyFor(call);

    // cacheOnly must never touch the network, even for a request that cannot
    // be keyed; that is simply a miss.
    if (policy == CachePolicy.cacheOnly && cacheKey == null) {
      return left(ErrorSource.cacheError.getFailure());
    }

    if (cacheKey != null && policy != CachePolicy.networkFirst) {
      final cached = await _readCache(cacheKey, call.cacheMaxAge);
      if (cached != null) return right(cached);
      if (policy == CachePolicy.cacheOnly) {
        return left(ErrorSource.cacheError.getFailure());
      }
    }

    final result = await _dispatch(call);

    if (cacheKey == null) return result;

    return result.fold(
      (failure) async {
        // networkFirst is the only policy that can still succeed here: serve
        // the last-known-good response rather than an error screen.
        if (policy != CachePolicy.networkFirst) return left(failure);
        final cached = await _readCache(cacheKey, call.cacheMaxAge);
        return cached == null ? left(failure) : right(cached);
      },
      (response) async {
        await _writeCache(cacheKey, response);
        return right(response);
      },
    );
  }

  /// The cache key for [call], or `null` when it cannot be cached safely.
  ///
  /// Additions are suffixes on the url key, made only when they apply, so the
  /// key for an ordinary JSON GET is unchanged and existing entries stay
  /// readable:
  ///
  /// - a **body**, JSON-encoded: `get` accepts one, and without it two
  ///   searches differing only in their body shared an entry, so the second
  ///   was answered with the first's results. A body that will not encode
  ///   returns `null`.
  /// - a **plain-text** response type: under the shared key, a `plain` caller
  ///   was handed the Map a JSON caller of the same url had cached. Binary
  ///   types never reach here (see [_effectiveCachePolicy]).
  String? _cacheKeyFor(_Call call) {
    final buffer = StringBuffer(buildCacheKey(
      baseUrl: ApiServices._config.baseUrl,
      endpoint: call.endpoint,
      params: call.params,
    ));
    if (call.responseType == ResponseType.plain) buffer.write('|as:plain');
    final data = call.data;
    if (data != null) {
      try {
        buffer.write('|body:${jsonEncode(data)}');
      } catch (_) {
        return null;
      }
    }
    return buffer.toString();
  }

  /// Reports an outcome to the observer and passes it straight through.
  Either<Failure, Response> _notify(Either<Failure, Response> result) {
    return result.fold(
      (failure) {
        _notifyFailure(failure, failure.requestOptions);
        return left(failure);
      },
      (response) {
        _notifyResponse(response);
        return right(response);
      },
    );
  }

  /// Middle layer: collapses concurrent identical requests onto one call.
  Future<Either<Failure, Response>> _dispatch(_Call call) {
    final key = _dedupeKey(call);
    if (key == null) return _performRequest(call);

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _performRequest(call);
    _inFlight[key] = future;

    // Only the originator owns the entry, so the follower awaiting `existing`
    // above never removes it out from under a later caller.
    return future.whenComplete(() => _inFlight.remove(key));
  }

  /// The de-duplication key for [call], or `null` when it must go out alone.
  String? _dedupeKey(_Call call) {
    // A caller-supplied token is theirs to cancel. Sharing one network call
    // between two callers would let either of them cancel the other's request,
    // so opt out rather than surprise them.
    //
    // A tag is the same hazard by another name: cancelRequest(tag: 'feed')
    // would abort a collapsed request that a caller under a different tag —
    // or no tag at all — is still waiting on.
    //
    // Progress callbacks belong to one caller too. Only the originator's are
    // handed to Dio, so a follower's progress bar would sit at zero until the
    // response arrived.
    if (!call.dedupe ||
        call.cancelToken != null ||
        call.tag != null ||
        call.onSendProgress != null ||
        call.onReceiveProgress != null) {
      return null;
    }

    return buildRequestKey(
      method: call.method.value,
      baseUrl: ApiServices._config.baseUrl,
      endpoint: call.endpoint,
      params: call.params,
      data: call.data,
      headers: call.headers,
      responseType: call.responseType?.name,
    );
  }

  /// Innermost layer: connectivity and the Dio call.
  Future<Either<Failure, Response>> _performRequest(_Call call) {
    return _tracked(call.cancelToken, call.tag, (token) async {
      final offline = await _checkConnectivity();
      if (offline != null) return left(offline);
      // Cancelled while the probe ran — by cancelRequest(), or a reset() on
      // logout. Nothing has been sent, so nothing should be.
      if (token.isCancelled) return left(ErrorSource.cancel.getFailure());

      final result = await _throughGate(
        token,
        (token) => _dio.request(
          call.endpoint,
          data: call.data,
          queryParameters: call.params,
          options: Options(
            method: call.method.value,
            receiveTimeout: call.receiveTimeout,
            sendTimeout: call.sendTimeout,
            responseType: call.responseType,
            headers: _headersFor(call.data, call.headers),
          ),
          cancelToken: token,
          onSendProgress: call.onSendProgress,
          onReceiveProgress: call.onReceiveProgress,
        ),
      );
      return result.flatMap(_evaluate);
    });
  }

  /// Runs [body] with a token registered for [cancelRequest] for the whole of
  /// the request's life — the connectivity probe and the queue included, not
  /// only the network call. Registered any later, a cancelRequest() or a
  /// reset() that landed during the probe missed the request, which then went
  /// out anyway.
  Future<Either<Failure, Response>> _tracked(
    CancelToken? cancelToken,
    String? tag,
    Future<Either<Failure, Response>> Function(CancelToken token) body,
  ) async {
    final token = cancelToken ?? CancelToken();
    (_activeTokens[token] ??= []).add(tag);
    // A request reaching a client that reset() has discarded — an upload
    // that was still reading its files, say — must not go out either.
    if (_closed) token.cancel(_closedReason);
    try {
      return await body(token);
    } finally {
      final tags = _activeTokens[token];
      if (tags != null) {
        tags.remove(tag);
        if (tags.isEmpty) _activeTokens.remove(token);
      }
    }
  }

  static const String _closedReason = 'ApiServices.reset()';

  /// Called by `ApiServices.reset()`: cancels everything in flight and
  /// refuses anything that arrives later.
  void _close() {
    _closed = true;
    cancelRequest(cancellationReason: _closedReason);
  }

  /// Runs [send] once the concurrency gate admits it.
  ///
  /// A request made on behalf of a token refresh skips the gate: the requests
  /// that `401`'d hold their slots while they wait for it, so queueing it
  /// behind them deadlocked a cap of one. See `refresh_zone.dart`.
  Future<Either<Failure, Response>> _throughGate(
    CancelToken token,
    Future<Response> Function(CancelToken token) send,
  ) async {
    final gated = !isInsideTokenRefresh;
    // A cancel while queued fails the wait itself. No slot was taken, so
    // there is none to release, and no request was built to attach.
    if (gated && !await _gate.acquire(token)) {
      return left(ErrorSource.cancel.getFailure());
    }
    try {
      return right(await send(token));
    } catch (e) {
      return left(_toFailure(e));
    } finally {
      if (gated) _gate.release();
    }
  }

  /// Resolves what a request may actually do with the cache.
  ///
  /// `ApiConfig.cacheEnabled: false` wins over anything a call site asked for,
  /// so a project that must not persist responses cannot be undone by one
  /// stray `cachePolicy:` argument.
  ///
  /// **Caching is GET-only, and that has to be enforced here rather than left
  /// to the method signatures.** Only `get`/`getAs` expose a `cachePolicy`
  /// parameter, so the contract looks self-enforcing — but
  /// `ApiConfig.defaultCachePolicy` applies to every request that does not
  /// name one, which is every `post`, `put`, `patch`, `delete`, `head` and
  /// `options` there is. A project that set a project-wide policy would have
  /// its writes served from the cache: the second identical `POST /orders`
  /// would return the first one's response without ever reaching the server.
  /// Cache keys carry no method or body either, so a `POST` and a `GET` to one
  /// path share an entry.
  ///
  /// Binary responses are not cached either. Entries are stored as JSON, so a
  /// `bytes` body would come back as a `List<dynamic>` rather than the
  /// `Uint8List` the caller asked for, and a `stream` body cannot be stored at
  /// all. Worse, the key has no response type in it, so a `bytes` caller could
  /// be served a map cached by a JSON caller of the same url.
  CachePolicy _effectiveCachePolicy(_Call call) {
    final config = ApiServices._config;
    if (!config.cacheEnabled) return CachePolicy.networkOnly;
    if (call.method != HttpMethod.get) return CachePolicy.networkOnly;
    if (call.responseType == ResponseType.bytes ||
        call.responseType == ResponseType.stream) {
      return CachePolicy.networkOnly;
    }
    return call.cachePolicy ?? config.defaultCachePolicy;
  }

  /// Picks the headers for a request.
  ///
  /// A JSON `content-type` must not travel with a multipart body — it would
  /// replace the `multipart/form-data` type Dio generates, boundary and all,
  /// and the server would reject the upload. That applies to a caller's own
  /// headers too, not just the default set: an upload that also needs an
  /// `X-Tenant-Id` should not have to know to omit the content type.
  Map<String, String> _headersFor(Object? data, Map<String, String>? headers) {
    if (data is! FormData) return headers ?? _defaultHeader;
    if (headers == null) return {accept: applicationJson};

    final stripped = Map<String, String>.of(headers)
      ..removeWhere((key, value) =>
          key.toLowerCase() == contentType &&
          !value.toLowerCase().contains('multipart/'));
    return stripped;
  }

  /// Returns a `Failure` when the pre-flight connectivity check says we are
  /// offline, or `null` to proceed.
  Future<Failure?> _checkConnectivity() async {
    if (ApiServices._config.bypassConnectivityCheck) return null;
    if (await _networkInfo.isConnected) return null;

    // No request was ever built, so there are no RequestOptions to attach.
    return ErrorSource.noInternetConnection.getFailure();
  }

  /// Applies `ApiConfig.isSuccess` to a 2xx response.
  Either<Failure, Response> _evaluate(Response response) =>
      evaluateSuccess(response, ApiServices._config);

  /// Converts a thrown error into a `Failure`, keeping the request that
  /// produced it so the observer can say which call failed.
  Failure _toFailure(Object error) {
    return ErrorHandler.handle(error).failure.withRequest(
          error is DioException ? error.requestOptions : null,
        );
  }

  // ---------------------------------------------------------------------------
  // Cache
  // ---------------------------------------------------------------------------

  /// Rebuilds a [Response] from a cache entry, or `null` on a miss.
  ///
  /// Never throws: a cache that cannot be read is a miss, not an error worth
  /// failing the caller's request over.
  Future<Response?> _readCache(String key, Duration? maxAge) async {
    try {
      final entry = await _cache.getCacheData(key, maxAge: maxAge);
      if (entry == null || entry.syncData.isEmpty) return null;

      return Response(
        requestOptions: RequestOptions(path: key),
        statusCode: 200,
        data: jsonDecode(entry.syncData),
        extra: {fromCacheKey: true},
      );
    } catch (_) {
      return null;
    }
  }

  /// Stores a successful response. Best-effort — a body that will not encode
  /// (or a full disk) must never turn a good response into a failure.
  Future<void> _writeCache(String key, Response response) async {
    final status = response.statusCode ?? 0;
    if (status < 200 || status >= 300) return;

    final config = ApiServices._config;
    try {
      await _cache.setCacheData(
        key,
        jsonEncode(response.data),
        maxEntries: config.cacheMaxEntries,
        maxBytes: config.cacheMaxBytes,
      );
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Observer
  // ---------------------------------------------------------------------------

  void _notifyResponse(Response response) {
    final observer = ApiServices._config.observer;
    if (observer == null) return;
    try {
      observer.onResponse(response);
    } catch (_) {}
  }

  void _notifyFailure(Failure failure, RequestOptions? options) {
    final observer = ApiServices._config.observer;
    if (observer == null) return;
    try {
      observer.onFailure(failure, options);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Loader
  // ---------------------------------------------------------------------------

  // Reference-counted so concurrent requests share one indicator: onShow
  // fires only for the first in-flight request, onHide only once none remain.
  // The counter lives on ApiServices, since the indicator is global.

  /// Takes a hold on the loader, returning the epoch to hand back to
  /// [_hideLoader].
  int _showLoader() {
    ApiServices._activeLoadingCount++;
    if (ApiServices._activeLoadingCount == 1) {
      _callLoader(ApiServices._onLoadingShow);
    }
    return ApiServices._loaderEpoch;
  }

  /// Releases a hold taken in [epoch]. A hold from before the last
  /// `ApiServices.reset()` was already discarded with the count, so it is
  /// ignored rather than subtracted from requests made since.
  void _hideLoader(int epoch) {
    if (epoch != ApiServices._loaderEpoch) return;
    ApiServices._activeLoadingCount--;
    if (ApiServices._activeLoadingCount == 0) {
      _callLoader(ApiServices._onLoadingHide);
    }
  }

  /// Runs a loader callback, which must never break the request around it —
  /// the same rule the observer follows.
  ///
  /// The documented wiring makes a throw likely, not exotic:
  /// `navigatorKey.currentContext!` before the navigator has mounted,
  /// `currentState!.pop()` once something else has closed the dialog. A
  /// throwing `onShow` escaped as an exception and left the count stuck, so
  /// the loader never showed again; a throwing `onHide`, which runs in a
  /// `finally`, replaced the request's result with its own exception.
  static void _callLoader(void Function()? callback) {
    try {
      callback?.call();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Typed responses
  // ---------------------------------------------------------------------------

  /// Applies [parser] to a successful response, converting anything it throws
  /// into a `Failure` so no exception crosses the API boundary.
  Either<Failure, T> _parse<T>(
    Either<Failure, Response> result,
    T Function(dynamic data) parser,
  ) {
    return result.fold((failure) => left<Failure, T>(failure), (response) {
      try {
        return right<Failure, T>(parser(response.data));
      } catch (_) {
        // The HTTP call already reported success — this is a second,
        // distinct event: the response arrived and could not be understood.
        final failure = Failure(
          ErrorSource.parseError,
          ResponseCode.parseError,
          ResponseStrings.parseError,
          data: response.data,
          statusCode: response.statusCode,
          requestOptions: response.requestOptions,
        );
        _notifyFailure(failure, response.requestOptions);
        return left(failure);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // HTTP methods
  // ---------------------------------------------------------------------------

  @override
  Future<Either<Failure, Response>> get({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
    CachePolicy? cachePolicy,
    Duration? cacheMaxAge,
    bool dedupe = true,
  }) {
    return _sendRequest(
      _Call(
        HttpMethod.get,
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
        cachePolicy: cachePolicy,
        cacheMaxAge: cacheMaxAge,
        dedupe: dedupe,
      ),
      showLoader: showLoader,
    );
  }

  @override
  Future<Either<Failure, T>> getAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
    CachePolicy? cachePolicy,
    Duration? cacheMaxAge,
    bool dedupe = true,
  }) async {
    return _parse(
      await get(
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
        showLoader: showLoader,
        cachePolicy: cachePolicy,
        cacheMaxAge: cacheMaxAge,
        dedupe: dedupe,
      ),
      parser,
    );
  }

  @override
  Future<Either<Failure, Response>> post({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  }) {
    return _sendRequest(
      _Call(
        HttpMethod.post,
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
      ),
      showLoader: showLoader,
    );
  }

  @override
  Future<Either<Failure, T>> postAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  }) async {
    return _parse(
      await post(
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
        showLoader: showLoader,
      ),
      parser,
    );
  }

  @override
  Future<Either<Failure, Response>> put({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  }) {
    return _sendRequest(
      _Call(
        HttpMethod.put,
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
      ),
      showLoader: showLoader,
    );
  }

  @override
  Future<Either<Failure, T>> putAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  }) async {
    return _parse(
      await put(
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
        showLoader: showLoader,
      ),
      parser,
    );
  }

  @override
  Future<Either<Failure, Response>> delete({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  }) {
    return _sendRequest(
      _Call(
        HttpMethod.delete,
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
      ),
      showLoader: showLoader,
    );
  }

  @override
  Future<Either<Failure, T>> deleteAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  }) async {
    return _parse(
      await delete(
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
        showLoader: showLoader,
      ),
      parser,
    );
  }

  @override
  Future<Either<Failure, Response>> patch({
    required String endpoint,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  }) {
    return _sendRequest(
      _Call(
        HttpMethod.patch,
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
      ),
      showLoader: showLoader,
    );
  }

  @override
  Future<Either<Failure, T>> patchAs<T>({
    required String endpoint,
    required T Function(dynamic data) parser,
    Object? data,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  }) async {
    return _parse(
      await patch(
        endpoint: endpoint,
        data: data,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
        showLoader: showLoader,
      ),
      parser,
    );
  }

  @override
  Future<Either<Failure, Response>> head({
    required String endpoint,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    String? tag,
    bool showLoader = true,
    bool dedupe = true,
  }) {
    return _sendRequest(
      _Call(
        HttpMethod.head,
        endpoint: endpoint,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        cancelToken: cancelToken,
        tag: tag,
        dedupe: dedupe,
      ),
      showLoader: showLoader,
    );
  }

  @override
  Future<Either<Failure, Response>> options({
    required String endpoint,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
    bool dedupe = true,
  }) {
    return _sendRequest(
      _Call(
        HttpMethod.options,
        endpoint: endpoint,
        params: params,
        receiveTimeout: receiveTimeout,
        sendTimeout: sendTimeout,
        headers: headers,
        cancelToken: cancelToken,
        responseType: responseType,
        tag: tag,
        dedupe: dedupe,
      ),
      showLoader: showLoader,
    );
  }

  @override
  Future<Either<Failure, Response>> upload({
    required String endpoint,
    Map<String, dynamic> fields = const {},
    List<UploadFile> files = const [],
    HttpMethod method = HttpMethod.post,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
  }) async {
    final epoch = showLoader ? _showLoader() : null;
    try {
      final FormData formData;
      try {
        // Files are appended as entries, not put in the map: several files
        // under one field — `images` for a gallery — would be duplicate keys
        // there, and all but the last would silently vanish.
        formData = FormData.fromMap(fields);
        for (final file in files) {
          formData.files
              .add(MapEntry(file.field, await file.toMultipartFile()));
        }
      } catch (e) {
        // A missing or unreadable file should surface as a Failure like
        // anything else, not as an exception out of an Either-returning API.
        // Reported here because this never reaches _sendRequest.
        return _notify(left(_toFailure(e)));
      }

      return await _sendRequest(
        _Call(
          method,
          endpoint: endpoint,
          data: formData,
          params: params,
          receiveTimeout: receiveTimeout,
          sendTimeout: sendTimeout,
          headers: headers,
          onSendProgress: onSendProgress,
          cancelToken: cancelToken,
          responseType: responseType,
          tag: tag,
        ),
        // The loader is already held for the whole operation, file reads
        // included; nesting another show/hide would double-count it.
        showLoader: false,
      );
    } finally {
      if (epoch != null) _hideLoader(epoch);
    }
  }

  @override
  Future<Either<Failure, Response>> download({
    required String endpoint,
    required String savePath,
    Map<String, dynamic>? params,
    Duration? receiveTimeout,
    Duration? sendTimeout,
    Map<String, String>? headers,
    ProgressCallback? onReceiveProgress,
    CancelToken? cancelToken,
    String? tag,
    bool deleteOnError = true,
    bool showLoader = true,
  }) async {
    final epoch = showLoader ? _showLoader() : null;
    try {
      // download() has its own path rather than going through _sendRequest —
      // it streams to disk and no cache policy or de-duplication applies — so
      // it reports its own outcome.
      return _notify(await _tracked(cancelToken, tag, (token) async {
        final offline = await _checkConnectivity();
        if (offline != null) return left(offline);
        if (token.isCancelled) return left(ErrorSource.cancel.getFailure());

        return _throughGate(
          token,
          (token) => _dio.download(
            endpoint,
            savePath,
            queryParameters: params,
            options: Options(
              receiveTimeout: receiveTimeout,
              sendTimeout: sendTimeout,
              headers: headers ?? _defaultHeader,
            ),
            cancelToken: token,
            onReceiveProgress: onReceiveProgress,
            deleteOnError: deleteOnError,
          ),
        );
      }));
    } finally {
      if (epoch != null) _hideLoader(epoch);
    }
  }

  @override
  void cancelRequest({String? tag, String cancellationReason = ''}) {
    final targets = _activeTokens.entries
        .where((entry) => tag == null || entry.value.contains(tag))
        .map((entry) => entry.key)
        .toList();

    for (final token in targets) {
      token.cancel(cancellationReason);
    }
  }
}

/// Everything one call asked for, carried down the pipeline as a single
/// value rather than re-listed as fifteen named parameters at every layer —
/// where forgetting to forward one compiles cleanly and silently drops it.
class _Call {
  final HttpMethod method;
  final String endpoint;
  final Object? data;
  final Map<String, dynamic>? params;
  final Duration? receiveTimeout;
  final Duration? sendTimeout;
  final Map<String, String>? headers;
  final ProgressCallback? onSendProgress;
  final ProgressCallback? onReceiveProgress;
  final CancelToken? cancelToken;
  final ResponseType? responseType;
  final String? tag;
  final CachePolicy? cachePolicy;
  final Duration? cacheMaxAge;
  final bool dedupe;

  const _Call(
    this.method, {
    required this.endpoint,
    this.data,
    this.params,
    this.receiveTimeout,
    this.sendTimeout,
    this.headers,
    this.onSendProgress,
    this.onReceiveProgress,
    this.cancelToken,
    this.responseType,
    this.tag,
    this.cachePolicy,
    this.cacheMaxAge,
    this.dedupe = false,
  });
}

/// Caps how many requests may be in flight at once, per client.
///
/// Sits at the innermost layer, below the cache and below de-duplication, so
/// the cap governs actual network calls: a cache hit never consumes a slot,
/// and two callers collapsed onto one request consume one between them.
///
/// A `null` limit is unlimited — nothing is tracked and [acquire] never
/// suspends.
class _RequestGate {
  final int? limit;

  int _active = 0;
  final Queue<Completer<bool>> _waiting = Queue<Completer<bool>>();

  /// A cap below one is rejected by `ApiConfig`'s assert in debug builds. In
  /// release it is raised to one rather than honoured: zero slots would queue
  /// every request forever, with the loader up.
  _RequestGate(int? limit) : limit = limit == null || limit > 0 ? limit : 1;

  /// Waits for a slot. Completes `true` once one is held, or `false` if
  /// [token] is cancelled while still queued — in which case no slot was
  /// taken and [release] must not be called.
  ///
  /// The wait happens outside Dio, so Dio's own cancellation cannot reach it.
  /// Without listening here, `cancelRequest()` on a queued request did
  /// nothing until a slot freed up — behind a long upload, that is the whole
  /// upload, with the loader showing throughout.
  Future<bool> acquire(CancelToken token) {
    final cap = limit;
    if (cap == null) return Future<bool>.value(true);

    if (_active < cap) {
      _active++;
      return Future<bool>.value(true);
    }

    final waiter = Completer<bool>();
    _waiting.add(waiter);
    token.whenCancel.then((_) {
      // Still queued means release() never handed it a slot.
      if (_waiting.remove(waiter)) waiter.complete(false);
    });
    return waiter.future;
  }

  void release() {
    if (limit == null) return;

    // The slot is handed straight to the next waiter rather than decrementing
    // and letting waiters race for it. That keeps _active honest and keeps
    // the queue first-in-first-out, so a request made early cannot be starved
    // by a burst of later ones.
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete(true);
      return;
    }

    _active--;
  }
}
