import 'package:baaba_api_handler/src/dio_factory.dart';
import 'package:baaba_api_handler/src/interceptors/token_refresh_interceptor.dart';
import 'package:baaba_api_handler/src/utils/constants.dart';
import 'package:baaba_api_handler/src/utils/error_handler.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/http_methods.dart';
import 'package:baaba_api_handler/src/utils/network_info.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';

/// A typed HTTP client wrapping Dio. All methods return `Either<Failure, Response>` —
/// use `.fold(onLeft, onRight)` to handle errors and successes without exceptions.
///
/// ---
///
/// ## Setup
///
/// Call [configure] once at app startup (before any request) to enable token
/// auth and automatic token refresh on 401:
///
/// ```dart
/// ApiServices.configure(
///   getToken: () async => await storage.read('token'),
///   onTokenRefresh: () async => await authRepo.refresh(),
///   onRefreshFailed: () => Get.offAllNamed(Routes.login),
/// );
/// ```
///
/// If you don't need token auth, skip [configure] and use [instance] directly.
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
/// Or inject via your DI framework and wrap in your own service layer:
///
/// ```dart
/// final result = await _apiServices.post(
///   endpoint: '/orders',
///   data: order.toJson(),
/// );
/// ```
abstract interface class ApiServices {
  static ApiServices? _instance;
  static bool _bypassConnectivityCheck = false;
  static void Function()? _onLoadingShow;
  static void Function()? _onLoadingHide;

  /// Returns the singleton instance.
  ///
  /// If [configure] was called first, the instance already has the token
  /// interceptor attached. Otherwise you get a plain Dio client.
  ///
  /// Pass a custom [dio] only in tests — do not use in production code.
  static ApiServices instance([Dio? dio]) {
    _instance ??= ApiServicesImplementation.instanceFor(
      dio: dio ?? DioFactory().getDio(),
    );
    return _instance!;
  }

  /// Configures [ApiServices] with token-based authentication and automatic
  /// token refresh on 401 responses.
  ///
  /// Call once at app startup before [instance]. Calling it again replaces the
  /// singleton (useful for re-login after logout).
  ///
  /// **Parameters:**
  ///
  /// - [getToken] — returns the current bearer token from storage. Called before
  ///   every request to attach the `Authorization` header.
  ///
  /// - [onTokenRefresh] — performs the actual refresh (e.g. calls `/auth/refresh`
  ///   and saves the new token). Return `true` on success, `false` on failure.
  ///
  /// - [onRefreshFailed] — called when refresh returns `false` or throws.
  ///   Use this to log the user out or navigate to the login screen.
  ///
  /// - [headerBuilder] — customises the auth headers built from the token.
  ///   Omit to use the default `{'Authorization': 'Bearer <token>'}`.
  ///
  /// - [bypassConnectivityCheck] — when `true`, skips the pre-flight internet
  ///   connectivity check. Use in staging/internal environments where external
  ///   connectivity probes fail because of proxies or firewalls.
  ///   See also [setConnectivityCheck].
  ///
  /// - [refreshTimeout] — how long a request that 401s while another refresh
  ///   is already in flight will wait for that refresh before giving up and
  ///   failing with the original error. Defaults to 30 seconds.
  ///
  /// **Example:**
  ///
  /// ```dart
  /// // main_production.dart
  /// ApiServices.configure(
  ///   getToken: () async => GetToken.getToken(),
  ///   onTokenRefresh: AuthSessionService.refreshToken,
  ///   onRefreshFailed: AuthSessionService.onSessionExpired,
  /// );
  ///
  /// // main_staging.dart — internal network with proxy
  /// ApiServices.configure(
  ///   getToken: () async => GetToken.getToken(),
  ///   onTokenRefresh: AuthSessionService.refreshToken,
  ///   onRefreshFailed: AuthSessionService.onSessionExpired,
  ///   bypassConnectivityCheck: true,
  /// );
  /// ```
  static void configure({
    required Future<String?> Function() getToken,
    required Future<bool> Function() onTokenRefresh,
    void Function()? onRefreshFailed,
    Map<String, String> Function(String token)? headerBuilder,
    bool bypassConnectivityCheck = false,
    Duration refreshTimeout = const Duration(seconds: 30),
  }) {
    _bypassConnectivityCheck = bypassConnectivityCheck;
    final dio = DioFactory().getDio();
    dio.interceptors.add(TokenRefreshInterceptor(
      dio: dio,
      getToken: getToken,
      onTokenRefresh: onTokenRefresh,
      onRefreshFailed: onRefreshFailed,
      headerBuilder: headerBuilder,
      refreshTimeout: refreshTimeout,
    ));
    _instance = ApiServicesImplementation.instanceFor(dio: dio);
  }

  /// Controls the connectivity check without calling [configure].
  ///
  /// Useful when you don't need token auth but are on an internal network where
  /// the connectivity probe (pinging external hosts) always fails.
  ///
  /// Set [enabled] to `false` to skip the check; defaults to `true` (check active).
  ///
  /// **Example:**
  ///
  /// ```dart
  /// // Call before configureDependencies() in your staging entry point.
  /// ApiServices.setConnectivityCheck(enabled: false);
  /// ```
  static void setConnectivityCheck({bool enabled = true}) {
    _bypassConnectivityCheck = !enabled;
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
    bool showLoader = true,
  });

  /// Sends a POST request to [endpoint].
  ///
  /// Use for creating resources or submitting forms. Pass the request body
  /// as [data] (a `Map`, a model's `.toJson()`, or `FormData` for file uploads).
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
  /// **File upload example:**
  ///
  /// ```dart
  /// final result = await _api.post(
  ///   endpoint: '/upload',
  ///   data: FormData.fromMap({
  ///     'file': await MultipartFile.fromFile(filePath),
  ///   }),
  ///   onSendProgress: (sent, total) => print('${sent / total * 100}%'),
  /// );
  /// ```
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
    bool deleteOnError = true,
    bool showLoader = true,
  });

  /// Cancels all in-flight requests.
  ///
  /// Call this when leaving a screen to abort any pending requests that are
  /// no longer needed (e.g. in `onClose` / `dispose`).
  ///
  /// **Example:**
  ///
  /// ```dart
  /// @override
  /// void onClose() {
  ///   _api.cancelRequest(cancellationReason: 'Screen closed');
  ///   super.onClose();
  /// }
  /// ```
  void cancelRequest({String cancellationReason = ''});
}

class ApiServicesImplementation implements ApiServices {
  final Dio _dio;
  final NetworkInfo _networkInfo;

  final Map<String, String> _defaultHeader = {
    contentType: applicationJson,
    accept: applicationJson,
  };

  // Tracks every active CancelToken so cancelRequest() can cancel all of them.
  final Set<CancelToken> _activeTokens = {};

  // Reference-counted so concurrent requests share one indicator: onShow
  // fires only for the first in-flight request, onHide only once none remain.
  int _activeLoadingCount = 0;

  ApiServicesImplementation._({required Dio dio, NetworkInfo? networkInfo})
      : _dio = dio,
        _networkInfo = networkInfo ?? NetworkInfo();

  factory ApiServicesImplementation.instanceFor({
    required Dio dio,
    NetworkInfo? networkInfo,
  }) {
    return ApiServicesImplementation._(dio: dio, networkInfo: networkInfo);
  }

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
    bool showLoader = true,
  }) async {
    if (showLoader) _showLoader();
    try {
      if (!ApiServices._bypassConnectivityCheck) {
        final isConnected = await _networkInfo.isConnected;
        if (!isConnected) {
          return left(ErrorSource.noInternetConnection.getFailure());
        }
      }

      final token = cancelToken ?? CancelToken();
      _activeTokens.add(token);
      try {
        final response = await _dio.request(
          endpoint,
          data: data,
          queryParameters: params,
          options: Options(
            method: method.value,
            receiveTimeout: receiveTimeout,
            sendTimeout: sendTimeout,
            headers: headers ?? _defaultHeader,
          ),
          cancelToken: token,
          onSendProgress: onSendProgress,
          onReceiveProgress: onReceiveProgress,
        );
        return right(response);
      } catch (e) {
        return left(ErrorHandler.handle(e).failure);
      } finally {
        _activeTokens.remove(token);
      }
    } finally {
      if (showLoader) _hideLoader();
    }
  }

  void _showLoader() {
    _activeLoadingCount++;
    if (_activeLoadingCount == 1) {
      ApiServices._onLoadingShow?.call();
    }
  }

  void _hideLoader() {
    _activeLoadingCount--;
    if (_activeLoadingCount == 0) {
      ApiServices._onLoadingHide?.call();
    }
  }

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
    bool showLoader = true,
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
      showLoader: showLoader,
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
      showLoader: showLoader,
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
      showLoader: showLoader,
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
      showLoader: showLoader,
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
      showLoader: showLoader,
    );
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
    bool deleteOnError = true,
    bool showLoader = true,
  }) async {
    if (showLoader) _showLoader();
    try {
      if (!ApiServices._bypassConnectivityCheck) {
        final isConnected = await _networkInfo.isConnected;
        if (!isConnected) {
          return left(ErrorSource.noInternetConnection.getFailure());
        }
      }

      final token = cancelToken ?? CancelToken();
      _activeTokens.add(token);
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
        return right(response);
      } catch (e) {
        return left(ErrorHandler.handle(e).failure);
      } finally {
        _activeTokens.remove(token);
      }
    } finally {
      if (showLoader) _hideLoader();
    }
  }

  @override
  void cancelRequest({String cancellationReason = ''}) {
    for (final token in _activeTokens.toList()) {
      token.cancel(cancellationReason);
    }
  }
}
