import 'dart:typed_data';

import 'package:baaba_api_handler/src/config/retry_policy.dart';
import 'package:baaba_api_handler/src/interceptors/network_retry_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _FailThenSucceedAdapter implements HttpClientAdapter {
  final int failCount;
  int callCount = 0;

  _FailThenSucceedAdapter({required this.failCount});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    callCount++;
    if (callCount <= failCount) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
      );
    }
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('NetworkRetryInterceptor', () {
    late Dio dio;

    setUp(() {
      dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      dio.interceptors.add(NetworkRetryInterceptor(
        dio: dio,
        policy: const RetryPolicy(
          baseDelay: Duration(milliseconds: 1),
          useJitter: false,
        ),
      ));
    });

    test('retries an idempotent GET on a connection error and succeeds',
        () async {
      final adapter = _FailThenSucceedAdapter(failCount: 1);
      dio.httpClientAdapter = adapter;

      final response = await dio.get('/test');

      expect(response.statusCode, 200);
      expect(adapter.callCount, 2); // original + one retry
    });

    test('does not retry a non-idempotent POST on a connection error',
        () async {
      final adapter = _FailThenSucceedAdapter(failCount: 1);
      dio.httpClientAdapter = adapter;

      await expectLater(
        dio.post('/test'),
        throwsA(isA<DioException>()),
      );

      expect(
          adapter.callCount, 1); // no retry — would risk duplicate side effects
    });

    test('gives up after maxRetries and surfaces the error', () async {
      final adapter = _FailThenSucceedAdapter(failCount: 10);
      dio.interceptors.removeWhere((i) => i is NetworkRetryInterceptor);
      dio.interceptors.add(NetworkRetryInterceptor(
        dio: dio,
        policy: const RetryPolicy(
          maxRetries: 2,
          baseDelay: Duration(milliseconds: 1),
          useJitter: false,
        ),
      ));
      dio.httpClientAdapter = adapter;

      await expectLater(
        dio.get('/test'),
        throwsA(isA<DioException>()),
      );

      expect(adapter.callCount, 3); // original + 2 retries
    });
  });
}
