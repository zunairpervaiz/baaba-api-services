import 'dart:async';
import 'dart:collection';

import 'package:baaba_api_handler/src/config/api_config.dart';
import 'package:baaba_api_handler/src/config/retry_policy.dart';
import 'package:baaba_api_handler/src/dio_factory.dart';
import 'package:baaba_api_handler/src/utils/constants.dart';
import 'package:baaba_api_handler/src/utils/error_handler.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/failure_mapper.dart';
import 'package:baaba_api_handler/src/utils/http_methods.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:baaba_api_handler/src/utils/redactor.dart';
import 'package:baaba_api_handler/src/utils/request_key.dart';
import 'package:baaba_api_handler/src/utils/success_check.dart';
import 'package:baaba_api_handler/src/utils/refresh_zone.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/src/utils/response_strings.dart';
import 'package:baaba_api_handler/src/utils/upload_file.dart';
import 'package:baaba_api_handler/src/utils/url_join.dart';
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
  /// The name of the client [init] and [instance] use when none is given.
  ///
  /// `init(config, name: ApiServices.defaultClient)` is the same call as
  /// `init(config)`, and `named(ApiServices.defaultClient)` returns
  /// [instance]'s client.
  static const String defaultClient = 'default';

  /// Every built client, by name.
  static final Map<String, ApiServices> _instances = {};

  /// The configuration each client was built from, by name. A client reads
  /// its own entry per call, so request-time settings take effect
  /// immediately — including for a caller still holding a client from before
  /// the last [init] under that name.
  static final Map<String, ApiConfig> _configs = {};

  /// The shared loading indicator, used by every client that has not been
  /// given its own with `configureLoader(name: ...)`.
  static final _Loader _sharedLoader = _Loader();

  /// Loaders configured for one client alone, by client name.
  static final Map<String, _Loader> _ownLoaders = {};

  /// The default client's configuration. Read-only — call [init] to change
  /// it. See [configOf] for a named client's.
  static ApiConfig get config => configOf(defaultClient);

  /// The configuration of the client called [name], or a plain
  /// `ApiConfig()` if no client by that name has been initialised.
  static ApiConfig configOf(String name) => _configs[name] ?? const ApiConfig();

  /// Whether a client called [name] has been built — by [init], or for the
  /// default client also by [instance].
  static bool isInitialized([String name = defaultClient]) =>
      _instances.containsKey(name);

  /// Configures a client and builds it.
  ///
  /// Call once at app startup, before any request. Calling it again replaces
  /// the client, which is what you want after a logout/re-login.
  ///
  /// Without a [name] this configures the default client, the one
  /// [instance] returns. Pass a [name] to build another, independent client
  /// — for a second backend with its own host, auth, retries, certificates
  /// or proxy — and reach it with [named]:
  ///
  /// ```dart
  /// ApiServices.init(ApiConfig(baseUrl: 'https://api.example.com'));
  /// ApiServices.init(
  ///   ApiConfig(baseUrl: 'https://partner.example.net', retry: ...),
  ///   name: 'partner',
  /// );
  ///
  /// final partner = ApiServices.named('partner');
  /// ```
  ///
  /// Each client has its own configuration, auth and token refresh, retry
  /// policy, concurrency cap, connectivity cache, de-duplication and
  /// cancellation. They share only the loading indicator, unless one is
  /// given its own — see [configureLoader].
  ///
  /// Settings read at *request* time — `bypassConnectivityCheck`,
  /// `isSuccess`, `onRejected`, `mapFailure`, and the observer's
  /// `onResponse`/`onFailure` — take effect immediately. Settings baked into
  /// the Dio client and its interceptors — `baseUrl`, timeouts,
  /// `defaultHeaders`, `logging`, `retry`, `auth`, `interceptors`,
  /// `httpClientAdapter`, `pinning`, `proxy`, `connectivityProbe`,
  /// `connectivityCacheTtl`, `maxConcurrentRequests`, and the observer's
  /// `onRequest` — apply to the client built here, so changing them means
  /// calling [init] again.
  ///
  /// See [ApiConfig] for every option.
  static void init(ApiConfig config, {String name = defaultClient}) {
    _configs[name] = config;
    _instances[name] = ApiServicesImplementation.instanceFor(
      dio: DioFactory().getDio(config: config),
      networkInfo: NetworkInfo(
        cacheTtl: config.connectivityCacheTtl,
        probe: config.connectivityProbe,
      ),
      name: name,
      ownsTransport: config.httpClientAdapter == null,
    );
  }

  /// Returns the default client, building one on first use if [init] was
  /// never called.
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
    return _instances[defaultClient] ??= ApiServicesImplementation.instanceFor(
      dio: dio ?? DioFactory().getDio(config: config),
      networkInfo: NetworkInfo(
        cacheTtl: config.connectivityCacheTtl,
        probe: config.connectivityProbe,
      ),
      ownsTransport: dio == null && config.httpClientAdapter == null,
    );
  }

  /// Returns the client [init] built under [name].
  ///
  /// Unlike [instance], a named client is never built on demand: one without
  /// its `init` would have no `baseUrl` and no auth, and its requests would
  /// go out against a relative path. Asking for a name that has not been
  /// initialised throws a [StateError] naming it — a wiring mistake, caught
  /// at the first call rather than as a stream of odd failures.
  ///
  /// `named(ApiServices.defaultClient)` behaves as [instance].
  static ApiServices named(String name) {
    if (name == defaultClient) return instance();
    final client = _instances[name];
    if (client == null) {
      throw StateError(
        'ApiServices: no client named "$name". '
        'Call ApiServices.init(config, name: \'$name\') first.',
      );
    }
    return client;
  }

  /// Discards clients, their configuration, and loader callbacks — every
  /// client, or only the one called [name].
  ///
  /// Two things this fixes. In tests, state set by one test no longer leaks
  /// into the next — call it in `tearDown`. In an app, it gives you a clean
  /// slate on logout, so the next user does not inherit the previous one's
  /// client.
  ///
  /// The next [instance] call builds a fresh default client. A named client
  /// must be [init]ed again before [named] will return it.
  ///
  /// Requests still in flight on a discarded client are cancelled, and
  /// complete with `ErrorSource.cancel`. Left running, one would still carry
  /// the previous user's token and report to the previous user's observer.
  /// [init] does not do this, since re-configuring is not necessarily a
  /// change of user.
  ///
  /// A loading indicator still showing is hidden first. The requests that
  /// would have hidden it are now stale and their release is ignored, so
  /// without this the dialog `onShow` opened would never be closed.
  ///
  /// With a [name], that client's own loader (if it has one) is discarded
  /// too. The shared loader belongs to the default client, so it is cleared
  /// by `reset()` and by `reset(name: ApiServices.defaultClient)` only — a
  /// named client's requests that were holding it release it normally as
  /// they complete with `ErrorSource.cancel`.
  static void reset({String? name}) {
    final names = name == null
        ? {..._instances.keys, ..._configs.keys, ..._ownLoaders.keys}
        : {name};
    for (final each in names) {
      final previous = _instances.remove(each);
      if (previous is ApiServicesImplementation) previous._close();
      _configs.remove(each);
      _ownLoaders.remove(each)?.discard();
    }
    if (name == null || name == defaultClient) _sharedLoader.discard();
  }

  /// Configures a loading indicator shown automatically around every
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
  ///
  /// **With several clients.** Without a [name] this is the shared
  /// indicator, and every client uses it — all of their requests count
  /// toward the one `onShow`/`onHide` pair, so a request on each of two
  /// clients still opens one dialog and closes it once. Pass a [name] to give
  /// that client an indicator of its own, with its own count; its requests
  /// then no longer touch the shared one.
  static void configureLoader({
    required void Function() onShow,
    required void Function() onHide,
    String? name,
  }) {
    final loader = name == null || name == defaultClient
        ? _sharedLoader
        : _ownLoaders.putIfAbsent(name, _Loader.new);
    loader
      ..onShow = onShow
      ..onHide = onHide;
  }

  /// The loader a request on the client called [name] holds.
  static _Loader _loaderFor(String name) => _ownLoaders[name] ?? _sharedLoader;

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
  /// **De-duplication.** Two identical GETs in flight at the same time share
  /// one network call by default. Pass `dedupe: false` to force a separate
  /// request. Automatically skipped when you supply your own [cancelToken] or
  /// a [tag], since cancelling one caller must not cancel the other, when
  /// you pass a progress callback, which only one caller's request can drive,
  /// and when you pass your own [receiveTimeout] or [sendTimeout], since one
  /// caller's deadline must not apply to another.
  ///
  /// **Per-call retry and extras** — on every request method:
  ///
  /// - [retryable] overrides the method's idempotency for this one call.
  ///   `true` lets it be retried like a `GET` — for a read-only `POST`, such
  ///   as a GraphQL query — still within `RetryPolicy.maxRetries`,
  ///   `retryableStatusCodes` and `retryIf`. `false` never retries it, not
  ///   even on a `429` or `503`. `null` (the default) leaves it to the method.
  /// - [extra] is copied into `RequestOptions.extra`, where `retryIf`, your
  ///   interceptors and the observer can read it. The flag is there too,
  ///   under `RetryPolicy.retryableKey`.
  ///
  /// ```dart
  /// await api.post(
  ///   endpoint: '/graphql',
  ///   data: query,
  ///   retryable: true,                  // GetBalance only reads
  ///   extra: {'operation': 'GetBalance'},
  /// );
  /// ```
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
    bool? retryable,
    Map<String, dynamic>? extra,
    bool showLoader = true,
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
    bool? retryable,
    Map<String, dynamic>? extra,
    bool showLoader = true,
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
  /// it, and repeating it could create the same record twice — unless you
  /// pass `retryable: true` for a call you know only reads. See [get] for
  /// `retryable` and `extra`.
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
  /// A timeout is not retried unless you pass `retryable: true`, since the
  /// server may already have stored the file. A `429` or `503` is, because the server said it did not process the
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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

  final Map<String, String> _defaultHeader = {
    contentType: applicationJson,
    accept: applicationJson,
  };

  /// For downloads and binary responses, which may be any type at all.
  static const Map<String, String> _anyContent = {accept: anyMediaType};

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

  /// The name this client was built under — [ApiServices.defaultClient]
  /// unless `init` was given one.
  final String _name;

  // The base this client's Dio was built with. The join must use it, not the
  // current config's: a caller holding this client across a later `init` of
  // the same name still sends through this Dio.
  final String? _baseUrl;

  /// Whether the package built this client's adapter, and so may close it
  /// on [_close]. A caller's own `httpClientAdapter` (or Dio, in tests) may
  /// be shared with another client and is theirs to close.
  final bool _ownsTransport;

  ApiServicesImplementation._({
    required Dio dio,
    NetworkInfo? networkInfo,
    required String name,
    bool ownsTransport = false,
  }) : _dio = dio,
       _ownsTransport = ownsTransport,
       _name = name,
       _baseUrl = ApiServices.configOf(name).baseUrl,
       _networkInfo = networkInfo ?? NetworkInfo(),
       _gate = _RequestGate(ApiServices.configOf(name).maxConcurrentRequests);

  /// This client's own configuration, read per call so request-time settings
  /// take effect immediately. Never another client's: every setting below
  /// reads through here.
  ApiConfig get _config => ApiServices.configOf(_name);

  /// The path handed to Dio for [endpoint]: a relative one always gains its
  /// leading slash, so the join with `baseUrl` neither doubles nor drops one.
  String _pathFor(String endpoint) => resolveEndpointPath(_baseUrl, endpoint);

  factory ApiServicesImplementation.instanceFor({
    required Dio dio,
    NetworkInfo? networkInfo,
    String name = ApiServices.defaultClient,
    bool ownsTransport = false,
  }) {
    return ApiServicesImplementation._(
      dio: dio,
      networkInfo: networkInfo,
      name: name,
      ownsTransport: ownsTransport,
    );
  }

  // ---------------------------------------------------------------------------
  // Request pipeline
  // ---------------------------------------------------------------------------

  /// Outermost layer: loader accounting and outcome reporting.
  Future<Either<Failure, Response>> _sendRequest(
    _Call call, {
    bool showLoader = true,
  }) async {
    final hold = showLoader ? _showLoader() : null;
    try {
      // Reported here, at the one layer that runs once per caller. Deeper
      // layers are shared: de-duplication collapses two callers onto one
      // _performRequest, so notifying from there would emit a single event
      // for two calls.
      return _notify(await _dispatch(call));
    } finally {
      if (hold != null) _hideLoader(hold);
    }
  }

  /// Reports an outcome to the observer and passes it straight through.
  Either<Failure, Response> _notify(Either<Failure, Response> result) {
    return result.fold(
      (raw) {
        // Mapped here, at the per-caller exit, so the observer reports what
        // the caller actually receives.
        final failure = mapFailure(raw, _config);
        _notifyFailure(failure);
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
    //
    // Per-call timeouts too: a follower relying on the default 60s would
    // otherwise inherit an originator's 2s deadline and fail with its timeout.
    //
    // A request made from inside onTokenRefresh skips the concurrency gate,
    // but a follower never reaches the gate — it waits on the originator. If
    // that originator is queued behind the request awaiting this refresh,
    // collapsing onto it is the very deadlock the bypass exists to prevent.
    if (!call.dedupe ||
        isInsideTokenRefresh ||
        call.cancelToken != null ||
        call.tag != null ||
        call.onSendProgress != null ||
        call.onReceiveProgress != null ||
        call.receiveTimeout != null ||
        call.sendTimeout != null) {
      return null;
    }

    return buildRequestKey(
      method: call.method.value,
      baseUrl: _config.baseUrl,
      endpoint: call.endpoint,
      params: call.params,
      data: call.data,
      headers: call.headers,
      responseType: call.responseType?.name,
      extra: _extraFor(call.retryable, call.extra),
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
          _pathFor(call.endpoint),
          data: call.data,
          queryParameters: call.params,
          options: Options(
            method: call.method.value,
            receiveTimeout: call.receiveTimeout,
            sendTimeout: call.sendTimeout,
            responseType: call.responseType,
            headers: _headersFor(call.data, call.headers, call.responseType),
            extra: _extraFor(call.retryable, call.extra),
          ),
          cancelToken: token,
          onSendProgress: call.onSendProgress,
          onReceiveProgress: call.onReceiveProgress,
        ),
      );
      // HEAD has no body, so a body-reading isSuccess — the documented
      // `r.data['success'] == true` shape — would throw on every call, and a
      // throwing predicate counts as a rejection. Skipped, as for download.
      if (call.method == HttpMethod.head) return result;
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
    // Releases the pooled connections now rather than leaving them open until
    // the idle timeout. Not forced: everything in flight was just cancelled,
    // and nothing new reaches Dio — _tracked cancels it first.
    if (_ownsTransport) _dio.close();
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

  /// Picks the headers for a request.
  ///
  /// A JSON `content-type` must not travel with a multipart body — it would
  /// replace the `multipart/form-data` type Dio generates, boundary and all,
  /// and the server would reject the upload. That applies to a caller's own
  /// headers too, not just the default set: an upload that also needs an
  /// `X-Tenant-Id` should not have to know to omit the content type.
  Map<String, String> _headersFor(
    Object? data,
    Map<String, String>? headers,
    ResponseType? responseType,
  ) {
    // A caller asking for bytes or a stream wants a file, not JSON. Sending
    // `Accept: application/json` for one gets a 406 from servers that honour
    // it — static file handlers in particular.
    if (headers == null &&
        (responseType == ResponseType.bytes ||
            responseType == ResponseType.stream)) {
      return data is FormData
          ? _anyContent
          : {..._defaultHeader, ..._anyContent};
    }
    if (data is! FormData) return headers ?? _defaultHeader;
    if (headers == null) return {accept: applicationJson};

    final stripped = Map<String, String>.of(headers)
      ..removeWhere(
        (key, value) =>
            key.toLowerCase() == contentType &&
            !value.toLowerCase().contains('multipart/'),
      );
    return stripped;
  }

  /// Returns a `Failure` when the pre-flight connectivity check says we are
  /// offline, or `null` to proceed.
  Future<Failure?> _checkConnectivity() async {
    if (_config.bypassConnectivityCheck) return null;
    if (await _networkInfo.isConnected) return null;

    // No request was ever built, so there are no RequestOptions to attach.
    return ErrorSource.noInternetConnection.getFailure();
  }

  /// Applies `ApiConfig.isSuccess` to a 2xx response.
  Either<Failure, Response> _evaluate(Response response) =>
      evaluateSuccess(response, _config);

  /// Converts a thrown error into a `Failure`, keeping the request that
  /// produced it so the observer can say which call failed.
  Failure _toFailure(Object error) {
    return ErrorHandler.handle(
      error,
    ).failure.withRequest(error is DioException ? error.requestOptions : null);
  }

  // ---------------------------------------------------------------------------
  // Observer
  // ---------------------------------------------------------------------------

  // The observer gets masked copies — `ApiLogOptions.redact` — while the
  // caller gets the response and failure exactly as they arrived. Masking is
  // inside the try: it must no more break a request than the observer may.

  void _notifyResponse(Response response) {
    final observer = _config.observer;
    if (observer == null) return;
    try {
      final redactor = Redactor.forConfig(_config);
      observer.onResponse(redactor?.response(response) ?? response);
    } catch (_) {}
  }

  void _notifyFailure(Failure failure) {
    final observer = _config.observer;
    if (observer == null) return;
    try {
      final redactor = Redactor.forConfig(_config);
      final seen = redactor?.failure(failure) ?? failure;
      observer.onFailure(seen, seen.requestOptions);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Loader
  // ---------------------------------------------------------------------------

  // Reference-counted so concurrent requests share one indicator: onShow
  // fires only for the first in-flight request, onHide only once none remain.
  // The count lives on the loader, not the client: the shared indicator is
  // one widget driven by every client that has no loader of its own.

  /// Takes a hold on this client's loader, to hand back to [_hideLoader].
  ///
  /// The hold names the loader it was taken on, so it is released there even
  /// if `configureLoader(name: ...)` gives the client a different one while
  /// the request is in flight.
  _LoaderHold _showLoader() {
    final loader = ApiServices._loaderFor(_name);
    return (loader, loader.acquire());
  }

  void _hideLoader(_LoaderHold hold) => hold.$1.release(hold.$2);

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
        final failure = mapFailure(
          Failure(
            ErrorSource.parseError,
            ResponseCode.parseError,
            ResponseStrings.parseError,
            data: response.data,
            statusCode: response.statusCode,
            requestOptions: response.requestOptions,
          ),
          _config,
        );
        _notifyFailure(failure);
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
    bool? retryable,
    Map<String, dynamic>? extra,
    bool showLoader = true,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
    bool showLoader = true,
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
        retryable: retryable,
        extra: extra,
        showLoader: showLoader,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
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
        retryable: retryable,
        extra: extra,
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
    bool? retryable,
    Map<String, dynamic>? extra,
    bool showLoader = true,
  }) async {
    final hold = showLoader ? _showLoader() : null;
    try {
      // Tracked from the start, so a cancelRequest(tag:) that lands while the
      // files are still being read stops the upload rather than missing it.
      return await _tracked(cancelToken, tag, (token) async {
        final FormData formData;
        try {
          // Files are appended as entries, not put in the map: several files
          // under one field — `images` for a gallery — would be duplicate keys
          // there, and all but the last would silently vanish.
          formData = FormData.fromMap(fields);
          for (final file in files) {
            formData.files.add(
              MapEntry(file.field, await file.toMultipartFile()),
            );
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
            cancelToken: token,
            responseType: responseType,
            tag: tag,
            retryable: retryable,
            extra: extra,
          ),
          // The loader is already held for the whole operation, file reads
          // included; nesting another show/hide would double-count it.
          showLoader: false,
        );
      });
    } finally {
      if (hold != null) _hideLoader(hold);
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
    bool? retryable,
    Map<String, dynamic>? extra,
    bool deleteOnError = true,
    bool showLoader = true,
  }) async {
    final hold = showLoader ? _showLoader() : null;
    try {
      // download() has its own path rather than going through _sendRequest —
      // it streams to disk and de-duplication does not apply — so
      // it reports its own outcome.
      return _notify(
        await _tracked(cancelToken, tag, (token) async {
          final offline = await _checkConnectivity();
          if (offline != null) return left(offline);
          if (token.isCancelled) return left(ErrorSource.cancel.getFailure());

          return _throughGate(
            token,
            (token) => _dio.download(
              _pathFor(endpoint),
              savePath,
              queryParameters: params,
              options: Options(
                receiveTimeout: receiveTimeout,
                sendTimeout: sendTimeout,
                headers: headers ?? _anyContent,
                extra: _extraFor(retryable, extra),
              ),
              cancelToken: token,
              onReceiveProgress: onReceiveProgress,
              deleteOnError: deleteOnError,
            ),
          );
        }),
      );
    } finally {
      if (hold != null) _hideLoader(hold);
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

/// A hold on a loader: the loader, and the epoch it was taken in.
typedef _LoaderHold = (_Loader, int);

/// One loading indicator and the requests currently holding it.
class _Loader {
  void Function()? onShow;
  void Function()? onHide;

  /// Requests currently holding the indicator.
  int _count = 0;

  /// Bumped by [discard], so a request that was already holding the loader
  /// when the count was zeroed does not decrement the fresh count when it
  /// finishes. Without it the count went negative, and the next request's
  /// increment landed on zero — so the loader never showed again.
  int _epoch = 0;

  /// Takes a hold, returning the epoch to hand back to [release].
  int acquire() {
    _count++;
    if (_count == 1) _call(onShow);
    return _epoch;
  }

  /// Releases a hold taken in [epoch]. A hold from before the last [discard]
  /// was already dropped with the count, so it is ignored rather than
  /// subtracted from requests made since.
  void release(int epoch) {
    if (epoch != _epoch) return;
    _count--;
    if (_count == 0) _call(onHide);
  }

  /// Forgets the callbacks and every hold. An indicator still showing is
  /// hidden first: the holds that would have hidden it are now stale, so
  /// without this the dialog `onShow` opened would never be closed.
  void discard() {
    if (_count > 0) _call(onHide);
    onShow = null;
    onHide = null;
    _count = 0;
    _epoch++;
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
  static void _call(void Function()? callback) {
    try {
      callback?.call();
    } catch (_) {}
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
  final bool? retryable;
  final Map<String, dynamic>? extra;
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
    this.retryable,
    this.extra,
    this.dedupe = false,
  });
}

/// The `RequestOptions.extra` for a request: the caller's own [extra], plus
/// the per-call [retryable] flag under [RetryPolicy.retryableKey].
///
/// A copy, so the interceptors writing their own bookkeeping into it never
/// touch the caller's map.
Map<String, dynamic>? _extraFor(bool? retryable, Map<String, dynamic>? extra) {
  if (retryable == null && extra == null) return null;
  return {...?extra, RetryPolicy.retryableKey: ?retryable};
}

/// Caps how many requests may be in flight at once, per client.
///
/// Sits at the innermost layer, below de-duplication, so the cap governs
/// actual network calls: two callers collapsed onto one request consume one
/// slot between them.
///
/// A `null` limit is unlimited — nothing is tracked and [acquire] never
/// suspends.
class _RequestGate {
  final int? limit;

  int _active = 0;
  final Queue<({Completer<bool> waiter, CancelToken token})> _waiting =
      Queue<({Completer<bool> waiter, CancelToken token})>();

  /// Tokens this gate already listens to. A future cannot be unsubscribed
  /// from, so a listener per queued request kept every waiter alive until its
  /// token was cancelled — thousands, for an app sharing one long-lived token.
  /// One listener per token instead; an [Expando] so the gate never keeps a
  /// token alive.
  final Expando<bool> _listening = Expando<bool>('_RequestGate');

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
    _waiting.add((waiter: waiter, token: token));
    if (_listening[token] == null) {
      _listening[token] = true;
      token.whenCancel.then((_) => _cancelWaiting(token));
    }
    return waiter.future;
  }

  /// Fails every request still queued under [token]. Still queued means
  /// [release] never handed it a slot, so there is none to give back.
  void _cancelWaiting(CancelToken token) {
    final cancelled = [
      for (final entry in _waiting)
        if (identical(entry.token, token)) entry.waiter,
    ];
    _waiting.removeWhere((entry) => identical(entry.token, token));
    for (final waiter in cancelled) {
      waiter.complete(false);
    }
  }

  void release() {
    if (limit == null) return;

    // The slot is handed straight to the next waiter rather than decrementing
    // and letting waiters race for it. That keeps _active honest and keeps
    // the queue first-in-first-out, so a request made early cannot be starved
    // by a burst of later ones.
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().waiter.complete(true);
      return;
    }

    _active--;
  }
}
