import 'dart:typed_data';

import 'package:baaba_api_handler/src/config/retry_policy.dart';
import 'package:baaba_api_handler/src/interceptors/network_retry_interceptor.dart';
import 'package:baaba_api_handler/src/interceptors/token_refresh_interceptor.dart';
import 'package:baaba_api_handler/src/utils/replayable_request.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reads each request body to completion, exactly as a real transport does —
/// which is what consumes a FormData and makes a naive replay throw.
class _BodyReadingAdapter implements HttpClientAdapter {
  final List<int> statuses;
  final List<int> bodyLengths = [];
  int callCount = 0;

  _BodyReadingAdapter(this.statuses);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final index = callCount;
    callCount++;

    var length = 0;
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        length += chunk.length;
      }
    }
    bodyLengths.add(length);

    final status = index < statuses.length ? statuses[index] : 200;
    return ResponseBody.fromString('{}', status, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

FormData buildForm() => FormData.fromMap({
      'caption': 'Beach trip',
      'photo': MultipartFile.fromBytes(
        List<int>.filled(2048, 7),
        filename: 'photo.png',
      ),
    });

void main() {
  group('prepareForReplay', () {
    test('clones a FormData that has already been sent', () {
      final form = buildForm();
      form.finalize().drain<void>();
      expect(form.isFinalized, isTrue);

      final options = RequestOptions(path: '/upload', data: form);
      prepareForReplay(options);

      final replacement = options.data as FormData;
      expect(replacement, isNot(same(form)));
      expect(replacement.isFinalized, isFalse);
      expect(replacement.fields.single.value, 'Beach trip');
      expect(replacement.files.single.value.filename, 'photo.png');
    });

    test('leaves an unsent FormData alone', () {
      final form = buildForm();
      final options = RequestOptions(path: '/upload', data: form);

      prepareForReplay(options);

      expect(options.data, same(form));
    });

    test('leaves an ordinary JSON body alone', () {
      final body = {'name': 'Ada'};
      final options = RequestOptions(path: '/users', data: body);

      prepareForReplay(options);

      expect(options.data, same(body));
    });
  });

  group('NetworkRetryInterceptor with a multipart body', () {
    test('retries an upload on 503 and resends the full body', () async {
      // 503 bypasses the idempotency check — the server said it did not
      // process the request — so a POST upload does get retried. Without
      // cloning, the second attempt throws StateError from finalize().
      final adapter = _BodyReadingAdapter([503]);
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      dio.interceptors.add(NetworkRetryInterceptor(
        dio: dio,
        policy: const RetryPolicy(
          baseDelay: Duration(milliseconds: 1),
          useJitter: false,
        ),
      ));
      dio.httpClientAdapter = adapter;

      final response = await dio.post('/documents', data: buildForm());

      expect(response.statusCode, 200);
      expect(adapter.callCount, 2);
      // The retry must carry the same bytes, not an empty body.
      expect(adapter.bodyLengths.first, greaterThan(2048));
      expect(adapter.bodyLengths.last, adapter.bodyLengths.first);
    });

    test('a transport error on an upload is still not retried', () async {
      // POST stays gated on idempotency: the server may already have stored
      // the file before the connection dropped.
      final adapter = _BodyReadingAdapter([]);
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      dio.interceptors.add(NetworkRetryInterceptor(
        dio: dio,
        policy: const RetryPolicy(
          baseDelay: Duration(milliseconds: 1),
          useJitter: false,
        ),
      ));
      dio.httpClientAdapter = _ThrowingAdapter();

      await expectLater(
        dio.post('/documents', data: buildForm()),
        throwsA(isA<DioException>()),
      );
      expect(adapter.callCount, 0);
    });
  });

  group('TokenRefreshInterceptor with a multipart body', () {
    test('replays an upload after refreshing on 401', () async {
      // The likely real case: an upload large enough that the token expires
      // mid-flight.
      final adapter = _BodyReadingAdapter([401]);
      final dio = Dio(BaseOptions(baseUrl: 'https://example.com'));
      var token = 'stale';
      dio.interceptors.add(TokenRefreshInterceptor(
        dio: dio,
        getToken: () async => token,
        onTokenRefresh: () async {
          token = 'fresh';
          return true;
        },
      ));
      dio.httpClientAdapter = adapter;

      final response = await dio.post('/documents', data: buildForm());

      expect(response.statusCode, 200);
      expect(adapter.callCount, 2);
      expect(adapter.bodyLengths.last, adapter.bodyLengths.first);
    });
  });
}

class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
    );
  }

  @override
  void close({bool force = false}) {}
}
