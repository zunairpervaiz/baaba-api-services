import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:baaba_api_handler/src/api_cache_helper.dart';
import 'package:baaba_api_handler/src/config/api_config.dart';
import 'package:baaba_api_handler/src/config/auth_config.dart';
import 'package:baaba_api_handler/src/config/cache_policy.dart';
import 'package:baaba_api_handler/src/dio_factory.dart';
import 'package:baaba_api_handler/src/utils/api_log_options.dart';
import 'package:baaba_api_handler/src/utils/cache_key.dart';
import 'package:baaba_api_handler/src/utils/constants.dart';
import 'package:baaba_api_handler/src/utils/error_body.dart';
import 'package:baaba_api_handler/src/utils/error_handler.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/http_methods.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
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
  static void reset() {
    _instance = null;
    _config = const ApiConfig();
    _onLoadingShow = null;
    _onLoadingHide = null;
    _activeLoadingCount = 0;
  }

  /// Configures token authentication.
  ///
  /// Superseded by [init], which covers this and everything else in one place:
  ///
  /// ```dart
  /// ApiServices.init(ApiConfig(
  ///   bypassConnectivityCheck: false,
  ///   logging: const ApiLogOptions(),
  ///   auth: AuthConfig(
  ///     getToken: getToken,
  ///     onTokenRefresh: onTokenRefresh,
  ///     onRefreshFailed: onRefreshFailed,
  ///   ),
  /// ));
  /// ```
  @Deprecated(
    'Use ApiServices.init(ApiConfig(auth: AuthConfig(...))) instead. '
    'Will be removed in 3.0.0.',
  )
  static void configure({
    required Future<String?> Function() getToken,
    required Future<bool> Function() onTokenRefresh,
    void Function()? onRefreshFailed,
    Map<String, String> Function(String token)? headerBuilder,
    bool bypassConnectivityCheck = false,
    Duration refreshTimeout = const Duration(seconds: 30),
    ApiLogOptions logging = const ApiLogOptions(),
  }) {
    init(_config.copyWith(
      bypassConnectivityCheck: bypassConnectivityCheck,
      logging: logging,
      auth: AuthConfig(
        getToken: getToken,
        onTokenRefresh: onTokenRefresh,
        onRefreshFailed: onRefreshFailed,
        headerBuilder: headerBuilder,
        refreshTimeout: refreshTimeout,
      ),
    ));
  }

  /// Controls the connectivity check without rebuilding the client.
  ///
  /// Read at request time, so unlike most settings this still takes effect
  /// after [instance] has been called.
  @Deprecated(
    'Use ApiServices.init(ApiConfig(bypassConnectivityCheck: true)) instead. '
    'Will be removed in 3.0.0.',
  )
  static void setConnectivityCheck({bool enabled = true}) {
    _config = _config.copyWith(bypassConnectivityCheck: !enabled);
  }

  /// Configures the console logger.
  ///
  /// Must be called **before** the first [instance] call — the logger is part
  /// of the Dio client, which is built once and cached.
  @Deprecated(
    'Use ApiServices.init(ApiConfig(logging: ...)) instead. '
    'Will be removed in 3.0.0.',
  )
  static void setLogging(ApiLogOptions options) {
    _config = _config.copyWith(logging: options);
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

  // Tracks every active CancelToken, against the tag its request was made
  // under (null when it was made without one), so cancelRequest() can cancel
  // either everything or just one screen's worth.
  final Map<CancelToken, String?> _activeTokens = {};

  // Identical GETs in flight at the same time share one network call.
  final Map<String, Future<Either<Failure, Response>>> _inFlight = {};

  // Caps how many requests actually reach the network at once.
  final _RequestGate _gate;

  // Reference-counted so concurrent requests share one indicator: onShow
  // fires only for the first in-flight request, onHide only once none remain.
  // The counter lives on ApiServices, since the indicator is global.

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
    HttpMethod method, {
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
    bool dedupe = false,
  }) async {
    if (showLoader) _showLoader();
    try {
      // Reported here, at the one layer that runs once per caller. Deeper
      // layers are shared: de-duplication collapses two callers onto one
      // _performRequest, so notifying from there would emit a single event
      // for two calls.
      return _notify(await _resolve(
        method,
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
      ));
    } finally {
      if (showLoader) _hideLoader();
    }
  }

  /// Applies the cache policy around the network call.
  Future<Either<Failure, Response>> _resolve(
    HttpMethod method, {
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
    CachePolicy? cachePolicy,
    Duration? cacheMaxAge,
    bool dedupe = false,
  }) async {
    final policy = _effectiveCachePolicy(method, cachePolicy);

    final cacheKey = policy == CachePolicy.networkOnly
        ? null
        : buildCacheKey(
            baseUrl: ApiServices._config.baseUrl,
            endpoint: endpoint,
            params: params,
          );

    if (cacheKey != null && policy != CachePolicy.networkFirst) {
      final cached = await _readCache(cacheKey, cacheMaxAge);
      if (cached != null) return right(cached);
      if (policy == CachePolicy.cacheOnly) {
        return left(ErrorSource.cacheError.getFailure());
      }
    }

    final result = await _dispatch(
      method,
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
      dedupe: dedupe,
    );

    if (cacheKey == null) return result;

    return result.fold(
      (failure) async {
        // networkFirst is the only policy that can still succeed here: serve
        // the last-known-good response rather than an error screen.
        if (policy != CachePolicy.networkFirst) return left(failure);
        final cached = await _readCache(cacheKey, cacheMaxAge);
        return cached == null ? left(failure) : right(cached);
      },
      (response) async {
        await _writeCache(cacheKey, response);
        return right(response);
      },
    );
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
  Future<Either<Failure, Response>> _dispatch(
    HttpMethod method, {
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
    bool dedupe = false,
  }) {
    // A caller-supplied token is theirs to cancel. Sharing one network call
    // between two callers would let either of them cancel the other's request,
    // so opt out rather than surprise them.
    //
    // A tag is the same hazard by another name: cancelRequest(tag: 'feed')
    // would abort a collapsed request that a caller under a different tag —
    // or no tag at all — is still waiting on. Both opt out.
    final canDedupe = dedupe && cancelToken == null && tag == null;
    if (!canDedupe) {
      return _performRequest(
        method,
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
      );
    }

    final key = buildRequestKey(
      method: method.value,
      baseUrl: ApiServices._config.baseUrl,
      endpoint: endpoint,
      params: params,
      data: data,
    );

    final existing = _inFlight[key];
    if (existing != null) return existing;

    final future = _performRequest(
      method,
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
    );
    _inFlight[key] = future;

    // Only the originator owns the entry, so the follower awaiting `existing`
    // above never removes it out from under a later caller.
    return future.whenComplete(() => _inFlight.remove(key));
  }

  /// Innermost layer: connectivity, the Dio call, and outcome reporting.
  Future<Either<Failure, Response>> _performRequest(
    HttpMethod method, {
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
  }) async {
    final offline = await _checkConnectivity();
    if (offline != null) return left(offline);

    final token = cancelToken ?? CancelToken();
    // Registered before queuing, not after, so a request still waiting for a
    // slot can be cancelled like any other.
    _activeTokens[token] = tag;
    await _gate.acquire();
    try {
      final response = await _dio.request(
        endpoint,
        data: data,
        queryParameters: params,
        options: Options(
          method: method.value,
          receiveTimeout: receiveTimeout,
          sendTimeout: sendTimeout,
          responseType: responseType,
          headers: _headersFor(data, headers),
        ),
        cancelToken: token,
        onSendProgress: onSendProgress,
        onReceiveProgress: onReceiveProgress,
      );
      return _evaluate(response);
    } catch (e) {
      return left(_toFailure(e));
    } finally {
      _gate.release();
      _activeTokens.remove(token);
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
  CachePolicy _effectiveCachePolicy(HttpMethod method, CachePolicy? requested) {
    final config = ApiServices._config;
    if (!config.cacheEnabled) return CachePolicy.networkOnly;
    if (method != HttpMethod.get) return CachePolicy.networkOnly;
    return requested ?? config.defaultCachePolicy;
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
  Either<Failure, Response> _evaluate(Response response) {
    final isSuccess = ApiServices._config.isSuccess;
    if (isSuccess == null || isSuccess(response)) return right(response);

    // A 2xx the consumer's predicate rejected — e.g. {"success": false}.
    // Give them first refusal on the resulting Failure, so an API that
    // reports its own error codes in the body can surface one instead of
    // collapsing to a generic bad request. Wrapped, because a builder that
    // throws must not turn a response into an exception.
    final onRejected = ApiServices._config.onRejected;
    if (onRejected != null) {
      try {
        final custom = onRejected(response);
        if (custom != null) {
          return left(custom.withRequest(response.requestOptions));
        }
      } catch (_) {}
    }

    // Read the message from the body the same way a real error response would.
    final body = response.data;
    final message = extractErrorMessage(body);
    return left(Failure(
      ErrorSource.badRequest,
      ResponseCode.badRequest,
      message.isNotEmpty ? message : ResponseStrings.badRequest,
      data: body,
      statusCode: response.statusCode,
      requestOptions: response.requestOptions,
    ));
  }

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

  void _showLoader() {
    ApiServices._activeLoadingCount++;
    if (ApiServices._activeLoadingCount == 1) {
      ApiServices._onLoadingShow?.call();
    }
  }

  void _hideLoader() {
    ApiServices._activeLoadingCount--;
    if (ApiServices._activeLoadingCount == 0) {
      ApiServices._onLoadingHide?.call();
    }
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
      showLoader: showLoader,
      cachePolicy: cachePolicy,
      cacheMaxAge: cacheMaxAge,
      dedupe: dedupe,
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
      HttpMethod.head,
      endpoint: endpoint,
      params: params,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      headers: headers,
      cancelToken: cancelToken,
      tag: tag,
      showLoader: showLoader,
      dedupe: dedupe,
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
      HttpMethod.options,
      endpoint: endpoint,
      params: params,
      receiveTimeout: receiveTimeout,
      sendTimeout: sendTimeout,
      headers: headers,
      cancelToken: cancelToken,
      responseType: responseType,
      tag: tag,
      showLoader: showLoader,
      dedupe: dedupe,
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
    if (showLoader) _showLoader();
    try {
      final FormData formData;
      try {
        formData = FormData.fromMap({
          ...fields,
          for (final file in files) file.field: await file.toMultipartFile(),
        });
      } catch (e) {
        // A missing or unreadable file should surface as a Failure like
        // anything else, not as an exception out of an Either-returning API.
        // Reported here because this never reaches _sendRequest.
        return _notify(left(_toFailure(e)));
      }

      return await _sendRequest(
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
        // The loader is already held for the whole operation, file reads
        // included; nesting another show/hide would double-count it.
        showLoader: false,
      );
    } finally {
      if (showLoader) _hideLoader();
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
    if (showLoader) _showLoader();
    try {
      // download() has its own path rather than going through _sendRequest —
      // it streams to disk and no cache policy or de-duplication applies — so
      // it reports its own outcome.
      final offline = await _checkConnectivity();
      if (offline != null) return _notify(left(offline));

      final token = cancelToken ?? CancelToken();
      _activeTokens[token] = tag;
      await _gate.acquire();
      try {
        final response = await _dio.download(
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
        );
        return _notify(right(response));
      } catch (e) {
        return _notify(left(_toFailure(e)));
      } finally {
        _gate.release();
        _activeTokens.remove(token);
      }
    } finally {
      if (showLoader) _hideLoader();
    }
  }

  @override
  void cancelRequest({String? tag, String cancellationReason = ''}) {
    final targets = _activeTokens.entries
        .where((entry) => tag == null || entry.value == tag)
        .map((entry) => entry.key)
        .toList();

    for (final token in targets) {
      token.cancel(cancellationReason);
    }
  }
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
  final Queue<Completer<void>> _waiting = Queue<Completer<void>>();

  _RequestGate(this.limit);

  Future<void> acquire() {
    final cap = limit;
    if (cap == null) return Future<void>.value();

    if (_active < cap) {
      _active++;
      return Future<void>.value();
    }

    final waiter = Completer<void>();
    _waiting.add(waiter);
    return waiter.future;
  }

  void release() {
    if (limit == null) return;

    // The slot is handed straight to the next waiter rather than decrementing
    // and letting waiters race for it. That keeps _active honest and keeps
    // the queue first-in-first-out, so a request made early cannot be starved
    // by a burst of later ones.
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
      return;
    }

    _active--;
  }
}
