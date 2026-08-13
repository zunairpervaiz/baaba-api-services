import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/config/cache_policy.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/http_methods.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/src/utils/response_strings.dart';
import 'package:baaba_api_handler/src/utils/upload_file.dart';
import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';

/// One call made against a [FakeApiServices], captured for assertions.
class RecordedCall {
  final HttpMethod method;
  final String endpoint;
  final Object? data;
  final Map<String, dynamic>? params;
  final Map<String, String>? headers;

  /// Files passed to `upload`. Empty for every other method.
  final List<UploadFile> files;

  const RecordedCall({
    required this.method,
    required this.endpoint,
    this.data,
    this.params,
    this.headers,
    this.files = const [],
  });

  @override
  String toString() => '${method.value} $endpoint';
}

/// An in-memory [ApiServices] for tests, so you can exercise a repository or
/// controller without mocking Dio or standing up a server.
///
/// ```dart
/// import 'package:baaba_api_handler/testing.dart';
///
/// late FakeApiServices api;
///
/// setUp(() {
///   api = FakeApiServices();
///   api.stubJson(HttpMethod.get, '/users/1', {'id': 1, 'name': 'Ada'});
/// });
///
/// test('loads the user', () async {
///   final repo = UserRepository(api);
///
///   expect(await repo.find(1), isA<User>());
///   expect(api.recordedCalls.single.endpoint, '/users/1');
/// });
///
/// test('surfaces a server error', () async {
///   api.stubFailure(HttpMethod.get, '/users/1', statusCode: 500);
///
///   expect(await repo.find(1), isNull);
/// });
/// ```
///
/// **A missing stub throws.** Calling an endpoint you did not stub raises a
/// [StateError] naming the method and endpoint, so an unexpected call fails
/// loudly instead of quietly returning null and failing three asserts later.
class FakeApiServices implements ApiServices {
  final Map<String, List<Either<Failure, Response>>> _stubs = {};
  final List<RecordedCall> _recordedCalls = [];

  /// Every call made so far, in order.
  List<RecordedCall> get recordedCalls => List.unmodifiable(_recordedCalls);

  /// Reasons passed to [cancelRequest], in order.
  final List<String> cancellations = [];

  static String _key(HttpMethod method, String endpoint) =>
      '${method.value} $endpoint';

  /// Queues [result] for the next call to [method] [endpoint].
  ///
  /// Stub the same endpoint more than once to script a sequence — each call
  /// consumes one entry, and the last one repeats once the queue runs dry.
  /// That makes "fails, then succeeds on retry" straightforward to set up.
  void stub(
    HttpMethod method,
    String endpoint,
    Either<Failure, Response> result,
  ) {
    _stubs.putIfAbsent(_key(method, endpoint), () => []).add(result);
  }

  /// Stubs a successful JSON response — the common case.
  void stubJson(
    HttpMethod method,
    String endpoint,
    Object? body, {
    int statusCode = 200,
    Map<String, List<String>>? headers,
  }) {
    stub(
      method,
      endpoint,
      right(Response(
        requestOptions: RequestOptions(path: endpoint),
        statusCode: statusCode,
        data: body,
        headers: headers == null ? null : Headers.fromMap(headers),
      )),
    );
  }

  /// Stubs a failure.
  ///
  /// Pass [failure] for full control, or let one be built from [statusCode]
  /// and [body] the same way a real error response would be.
  void stubFailure(
    HttpMethod method,
    String endpoint, {
    Failure? failure,
    int statusCode = 400,
    Object? body,
    String? message,
  }) {
    if (failure != null) {
      stub(method, endpoint, left(failure));
      return;
    }

    final base = ErrorSource.badRequest.getFailure();
    stub(
      method,
      endpoint,
      left(Failure(
        base.errorType,
        base.code,
        message ?? base.message,
        data: body,
        statusCode: statusCode,
      )),
    );
  }

  /// Stubs the offline short-circuit, for testing no-connection paths.
  void stubOffline(HttpMethod method, String endpoint) {
    stub(method, endpoint, left(ErrorSource.noInternetConnection.getFailure()));
  }

  /// Stubs a `download` call, which is recorded under [HttpMethod.get].
  ///
  /// The `savePath` is captured as the recorded call's `data`, so a test can
  /// assert where the file would have been written:
  ///
  /// ```dart
  /// api.stubDownload('/files/report.pdf');
  /// await repository.fetchReport();
  /// expect(api.recordedCalls.single.data, endsWith('report.pdf'));
  /// ```
  void stubDownload(String endpoint, {int statusCode = 200}) {
    stubJson(HttpMethod.get, endpoint, null, statusCode: statusCode);
  }

  /// Clears stubs, recorded calls, and cancellations.
  void reset() {
    _stubs.clear();
    _recordedCalls.clear();
    cancellations.clear();
  }

  Future<Either<Failure, Response>> _respond(
    HttpMethod method,
    String endpoint, {
    Object? data,
    Map<String, dynamic>? params,
    Map<String, String>? headers,
    List<UploadFile> files = const [],
  }) async {
    _recordedCalls.add(RecordedCall(
      method: method,
      endpoint: endpoint,
      data: data,
      params: params,
      headers: headers,
      files: files,
    ));

    final queue = _stubs[_key(method, endpoint)];
    if (queue == null || queue.isEmpty) {
      throw StateError(
        'FakeApiServices: no stub for ${method.value} $endpoint.\n'
        'Add one with stubJson(HttpMethod.${method.name}, \'$endpoint\', ...) '
        'before the call.',
      );
    }

    // Keep the last entry so repeated polling of one endpoint keeps working.
    return queue.length == 1 ? queue.first : queue.removeAt(0);
  }

  Future<Either<Failure, T>> _respondAs<T>(
    HttpMethod method,
    String endpoint,
    T Function(dynamic data) parser, {
    Object? data,
    Map<String, dynamic>? params,
    Map<String, String>? headers,
  }) async {
    final result = await _respond(
      method,
      endpoint,
      data: data,
      params: params,
      headers: headers,
    );
    return result.fold(
      (failure) => left<Failure, T>(failure),
      (response) {
        // Mirror the real implementation: a throwing parser becomes a
        // Failure, never an exception. A double that lets it escape would
        // have tests passing against behaviour production does not have.
        try {
          return right<Failure, T>(parser(response.data));
        } catch (_) {
          return left<Failure, T>(Failure(
            ErrorSource.parseError,
            ResponseCode.parseError,
            ResponseStrings.parseError,
            data: response.data,
            statusCode: response.statusCode,
            requestOptions: response.requestOptions,
          ));
        }
      },
    );
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
    CachePolicy? cachePolicy,
    Duration? cacheMaxAge,
    bool dedupe = true,
  }) {
    return _respond(HttpMethod.get, endpoint,
        data: data, params: params, headers: headers);
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
    bool showLoader = true,
    CachePolicy? cachePolicy,
    Duration? cacheMaxAge,
    bool dedupe = true,
  }) {
    return _respondAs(HttpMethod.get, endpoint, parser,
        data: data, params: params, headers: headers);
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
    return _respond(HttpMethod.post, endpoint,
        data: data, params: params, headers: headers);
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
    bool showLoader = true,
  }) {
    return _respondAs(HttpMethod.post, endpoint, parser,
        data: data, params: params, headers: headers);
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
    return _respond(HttpMethod.put, endpoint,
        data: data, params: params, headers: headers);
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
    bool showLoader = true,
  }) {
    return _respondAs(HttpMethod.put, endpoint, parser,
        data: data, params: params, headers: headers);
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
    return _respond(HttpMethod.delete, endpoint,
        data: data, params: params, headers: headers);
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
    bool showLoader = true,
  }) {
    return _respondAs(HttpMethod.delete, endpoint, parser,
        data: data, params: params, headers: headers);
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
    return _respond(HttpMethod.patch, endpoint,
        data: data, params: params, headers: headers);
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
    bool showLoader = true,
  }) {
    return _respondAs(HttpMethod.patch, endpoint, parser,
        data: data, params: params, headers: headers);
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
    bool showLoader = true,
  }) {
    return _respond(method, endpoint,
        data: fields, params: params, headers: headers, files: files);
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
  }) {
    return _respond(HttpMethod.get, endpoint,
        data: savePath, params: params, headers: headers);
  }

  @override
  void cancelRequest({String cancellationReason = ''}) {
    cancellations.add(cancellationReason);
  }
}
