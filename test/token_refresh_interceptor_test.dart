import 'dart:typed_data';

import 'package:baaba_api_handler/src/interceptors/token_refresh_interceptor.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _MockAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions) handler;

  _MockAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _ok() => ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

ResponseBody _unauthorized() => ResponseBody.fromString('{"error":"Unauthorized"}', 401, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });

void main() {
  group('TokenRefreshInterceptor', () {
    late Dio dio;

    setUp(() {
      dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
    });

    test('attaches bearer token to every request', () async {
      String? capturedAuthHeader;

      dio.httpClientAdapter = _MockAdapter((options) async {
        capturedAuthHeader = options.headers['authorization'] as String?;
        return _ok();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'my-token',
        onTokenRefresh: () async => true,
      ));

      await dio.get('/test');

      expect(capturedAuthHeader, 'Bearer my-token');
    });

    test('retries on 401 and succeeds after token refresh', () async {
      int callCount = 0;
      int refreshCount = 0;

      dio.httpClientAdapter = _MockAdapter((options) async {
        callCount++;
        return callCount == 1 ? _unauthorized() : _ok();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'new-token',
        onTokenRefresh: () async {
          refreshCount++;
          return true;
        },
      ));

      final response = await dio.get('/test');

      expect(response.statusCode, 200);
      expect(refreshCount, 1);
      expect(callCount, 2);
    });

    test('does not retry a second time when _tokenRetried flag is set', () async {
      int callCount = 0;
      int refreshCount = 0;

      // Always return 401 — so the retry also gets 401, which should not trigger a second refresh.
      dio.httpClientAdapter = _MockAdapter((options) async {
        callCount++;
        return _unauthorized();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'token',
        onTokenRefresh: () async {
          refreshCount++;
          return true;
        },
      ));

      await expectLater(dio.get('/test'), throwsA(isA<DioException>()));

      expect(refreshCount, 1);
      expect(callCount, 2); // original + one retry
    });

    test('calls onRefreshFailed when onTokenRefresh returns false', () async {
      bool refreshFailedCalled = false;

      dio.httpClientAdapter = _MockAdapter((_) async => _unauthorized());

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'stale-token',
        onTokenRefresh: () async => false,
        onRefreshFailed: () => refreshFailedCalled = true,
      ));

      await expectLater(dio.get('/test'), throwsA(isA<DioException>()));

      expect(refreshFailedCalled, isTrue);
    });

    test('calls onRefreshFailed when onTokenRefresh throws', () async {
      bool refreshFailedCalled = false;

      dio.httpClientAdapter = _MockAdapter((_) async => _unauthorized());

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'token',
        onTokenRefresh: () async => throw Exception('network error during refresh'),
        onRefreshFailed: () => refreshFailedCalled = true,
      ));

      await expectLater(dio.get('/test'), throwsA(isA<DioException>()));

      expect(refreshFailedCalled, isTrue);
    });

    test('uses custom headerBuilder when provided', () async {
      String? capturedHeader;

      dio.httpClientAdapter = _MockAdapter((options) async {
        capturedHeader = options.headers['x-api-key'] as String?;
        return _ok();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => 'secret',
        onTokenRefresh: () async => true,
        headerBuilder: (token) => {'x-api-key': token},
      ));

      await dio.get('/test');

      expect(capturedHeader, 'secret');
    });

    test('skips header injection when getToken returns null', () async {
      String? capturedAuthHeader = 'initial';

      dio.httpClientAdapter = _MockAdapter((options) async {
        capturedAuthHeader = options.headers['authorization'] as String?;
        return _ok();
      });

      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => null,
        onTokenRefresh: () async => true,
      ));

      await dio.get('/test');

      expect(capturedAuthHeader, isNull);
    });
  });
}
