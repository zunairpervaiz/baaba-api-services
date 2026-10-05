import 'package:baaba_api_handler/src/api_service.dart';
import 'package:baaba_api_handler/src/observer/api_observer.dart';
import 'package:baaba_api_handler/src/utils/error_handler.dart';
import 'package:baaba_api_handler/src/utils/error_source_extension.dart';
import 'package:baaba_api_handler/src/utils/failure.dart';
import 'package:baaba_api_handler/src/utils/http_methods.dart';
import 'package:baaba_api_handler/src/utils/response_code.dart';
import 'package:baaba_api_handler/src/utils/response_strings.dart';
import 'package:baaba_api_handler/src/utils/success_check.dart';
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

  /// The `tag` the call was made under, or `null` if it was untagged. Lets a
  /// test assert that a screen's requests are tagged for cancellation.
  final String? tag;

  const RecordedCall({
    required this.method,
    required this.endpoint,
    this.data,
    this.params,
    this.headers,
    this.files = const [],
    this.tag,
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
/// It behaves like the real client where that shapes an outcome:
/// `ApiConfig.isSuccess`, an already-cancelled `CancelToken`, and
/// `ApiConfig.observer` all apply exactly as they do in production.
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

  /// The `tag` passed to each [cancelRequest] call, in order — `null` for a
  /// call that cancelled everything. Parallel to [cancellations].
  final List<String?> cancelledTags = [];

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

  /// Stubs a JSON response — usually a successful one.
  ///
  /// A [statusCode] outside `2xx` becomes a failure, as it does in production
  /// (Dio rejects it), built from the status and [body] like [stubFailure].
  void stubJson(
    HttpMethod method,
    String endpoint,
    Object? body, {
    int statusCode = 200,
    Map<String, List<String>>? headers,
  }) {
    if (statusCode < 200 || statusCode >= 300) {
      stub(method, endpoint, left(failureForStatus(statusCode, body)));
      return;
    }
    stub(
      method,
      endpoint,
      right(
        Response(
          requestOptions: RequestOptions(path: endpoint),
          statusCode: statusCode,
          data: body,
          headers: headers == null ? null : Headers.fromMap(headers),
        ),
      ),
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

    // Built exactly as a real error response is: a 401 is `unauthorized`,
    // and the body's own message wins over the generic one. It used to be
    // `badRequest` with the generic text whatever the status — so consumer
    // code branching on `ErrorSource.unauthorized` could not be tested.
    final built = failureForStatus(statusCode, body);
    stub(
      method,
      endpoint,
      left(
        message == null
            ? built
            : Failure(
                built.errorType,
                built.code,
                message,
                data: built.data,
                statusCode: built.statusCode,
              ),
      ),
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
    cancelledTags.clear();
  }

  Future<Either<Failure, Response>> _respond(
    HttpMethod method,
    String endpoint, {
    Object? data,
    Map<String, dynamic>? params,
    Map<String, String>? headers,
    List<UploadFile> files = const [],
    String? tag,
    CancelToken? cancelToken,
    bool evaluate = true,
  }) async {
    _recordedCalls.add(
      RecordedCall(
        method: method,
        endpoint: endpoint,
        data: data,
        params: params,
        headers: headers,
        files: files,
        tag: tag,
      ),
    );

    final queue = _stubs[_key(method, endpoint)];
    if (queue == null || queue.isEmpty) {
      throw StateError(
        'FakeApiServices: no stub for ${method.value} $endpoint.\n'
        'Add one with stubJson(HttpMethod.${method.name}, \'$endpoint\', ...) '
        'before the call.',
      );
    }

    // Keep the last entry so repeated polling of one endpoint keeps working.
    final result = queue.length == 1 ? queue.first : queue.removeAt(0);

    // Production fails an already-cancelled request before sending it, so a
    // test of cancel-on-dispose sees the same Left here.
    if (cancelToken?.isCancelled ?? false) {
      return _report(left(ErrorSource.cancel.getFailure()));
    }

    // The offline short-circuit never builds a request, in production or
    // here; anything else "went out", so the observer hears about it and a
    // failure carries the request that produced it, as a real one does.
    final offline = result.fold(
      (f) => f.errorType == ErrorSource.noInternetConnection,
      (_) => false,
    );
    final options = offline
        ? null
        : RequestOptions(
            path: endpoint,
            method: method.value,
            queryParameters: params,
            headers: headers,
            data: data,
          );
    if (options != null) _observe((o) => o.onRequest(options));
    final sent = result.mapLeft(
      (f) => f.requestOptions == null ? f.withRequest(options) : f,
    );

    // ApiConfig.isSuccess applies here as it does in production, so a stubbed
    // {"success": false} is a Left in tests too. Not to HEAD or downloads:
    // production skips it there, since neither has a body in `data`.
    if (!evaluate) return _report(sent);
    return _report(
      sent.flatMap((response) => evaluateSuccess(response, ApiServices.config)),
    );
  }

  /// Reports an outcome to `ApiConfig.observer`, once per call, as the real
  /// client does, and passes it through.
  Either<Failure, Response> _report(Either<Failure, Response> result) {
    result.fold(
      (failure) =>
          _observe((o) => o.onFailure(failure, failure.requestOptions)),
      (response) => _observe((o) => o.onResponse(response)),
    );
    return result;
  }

  /// Calls the configured observer, if any. A throwing observer never breaks
  /// a call — the same guarantee production gives.
  static void _observe(void Function(ApiObserver observer) notify) {
    final observer = ApiServices.config.observer;
    if (observer == null) return;
    try {
      notify(observer);
    } catch (_) {}
  }

  Future<Either<Failure, T>> _respondAs<T>(
    HttpMethod method,
    String endpoint,
    T Function(dynamic data) parser, {
    Object? data,
    Map<String, dynamic>? params,
    Map<String, String>? headers,
    String? tag,
    CancelToken? cancelToken,
  }) async {
    final result = await _respond(
      method,
      endpoint,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
    );
    return result.fold((failure) => left<Failure, T>(failure), (response) {
      // Mirror the real implementation: a throwing parser becomes a
      // Failure, never an exception. A double that lets it escape would
      // have tests passing against behaviour production does not have.
      //
      // Production reports both: onResponse (already sent by _respond) for
      // the HTTP call, then onFailure for the body it could not parse.
      try {
        return right<Failure, T>(parser(response.data));
      } catch (_) {
        final failure = Failure(
          ErrorSource.parseError,
          ResponseCode.parseError,
          ResponseStrings.parseError,
          data: response.data,
          statusCode: response.statusCode,
          requestOptions: response.requestOptions,
        );
        _observe((o) => o.onFailure(failure, failure.requestOptions));
        return left<Failure, T>(failure);
      }
    });
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
    ResponseType? responseType,
    String? tag,
    bool showLoader = true,
    bool dedupe = true,
  }) {
    return _respond(
      HttpMethod.get,
      endpoint,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
    bool dedupe = true,
  }) {
    return _respondAs(
      HttpMethod.get,
      endpoint,
      parser,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
    return _respond(
      HttpMethod.post,
      endpoint,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
  }) {
    return _respondAs(
      HttpMethod.post,
      endpoint,
      parser,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
    return _respond(
      HttpMethod.put,
      endpoint,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
  }) {
    return _respondAs(
      HttpMethod.put,
      endpoint,
      parser,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
    return _respond(
      HttpMethod.delete,
      endpoint,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
  }) {
    return _respondAs(
      HttpMethod.delete,
      endpoint,
      parser,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
    return _respond(
      HttpMethod.patch,
      endpoint,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
  }) {
    return _respondAs(
      HttpMethod.patch,
      endpoint,
      parser,
      data: data,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
    return _respond(
      HttpMethod.head,
      endpoint,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
      evaluate: false,
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
    return _respond(
      HttpMethod.options,
      endpoint,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
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
  }) {
    return _respond(
      method,
      endpoint,
      data: fields,
      params: params,
      headers: headers,
      files: files,
      tag: tag,
      cancelToken: cancelToken,
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
    String? tag,
    bool deleteOnError = true,
    bool showLoader = true,
  }) {
    return _respond(
      HttpMethod.get,
      endpoint,
      data: savePath,
      params: params,
      headers: headers,
      tag: tag,
      cancelToken: cancelToken,
      evaluate: false,
    );
  }

  @override
  void cancelRequest({String? tag, String cancellationReason = ''}) {
    cancellations.add(cancellationReason);
    cancelledTags.add(tag);
  }
}
